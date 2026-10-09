package main

import (
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"beacle/shared"
	"github.com/gorilla/websocket"
	"golang.org/x/crypto/ssh"
	"golang.org/x/crypto/ssh/knownhosts"
)

// A shell on a saved SSH host. The app speaks the same terminal frames as to
// an agent shell (backend/terminal.go); here the other end is an SSH session
// this backend dials itself.

const (
	sshDialTimeout = 15 * time.Second
	sshKeepAlive   = 30 * time.Second
)

// hostKeyCallback trusts a host the first time it is seen and remembers its
// key in known_hosts, like ssh's accept-new; a key that changes later is
// refused.
func (h *SSHHosts) hostKeyCallback() (ssh.HostKeyCallback, error) {
	f, err := os.OpenFile(h.knownPath, os.O_CREATE|os.O_RDONLY, 0o600)
	if err != nil {
		return nil, err
	}
	f.Close()
	known, err := knownhosts.New(h.knownPath)
	if err != nil {
		return nil, err
	}
	return func(hostname string, remote net.Addr, key ssh.PublicKey) error {
		err := known(hostname, remote, key)
		var keyErr *knownhosts.KeyError
		if !errors.As(err, &keyErr) {
			return err
		}
		if len(keyErr.Want) > 0 {
			return fmt.Errorf("the host key of %s changed (%s) — if the server was reinstalled, remove its line from %s",
				hostname, ssh.FingerprintSHA256(key), h.knownPath)
		}
		h.mu.Lock()
		defer h.mu.Unlock()
		kf, err := os.OpenFile(h.knownPath, os.O_APPEND|os.O_WRONLY, 0o600)
		if err != nil {
			return err
		}
		defer kf.Close()
		_, err = kf.WriteString(knownhosts.Line([]string{knownhosts.Normalize(hostname)}, key) + "\n")
		return err
	}, nil
}

// dial logs in to host with whatever it has saved: the key first, then the
// password (also for servers that ask for it keyboard-interactively).
func (h *SSHHosts) dial(host *sshHostRecord) (*ssh.Client, error) {
	var auth []ssh.AuthMethod
	if host.Key != "" {
		signer, err := parseKey(host.Key, host.Passphrase)
		if err != nil {
			return nil, err
		}
		auth = append(auth, ssh.PublicKeys(signer))
	}
	if host.Password != "" {
		pw := host.Password
		auth = append(auth, ssh.Password(pw), ssh.KeyboardInteractive(
			func(_, _ string, questions []string, _ []bool) ([]string, error) {
				answers := make([]string, len(questions))
				for i := range answers {
					answers[i] = pw
				}
				return answers, nil
			}))
	}
	if len(auth) == 0 {
		return nil, errors.New("this host has no password or key saved — edit it and add one")
	}
	hk, err := h.hostKeyCallback()
	if err != nil {
		return nil, err
	}
	addr := net.JoinHostPort(host.Host, strconv.Itoa(host.Port))
	c, err := ssh.Dial("tcp", addr, &ssh.ClientConfig{
		User:            host.User,
		Auth:            auth,
		HostKeyCallback: hk,
		Timeout:         sshDialTimeout,
	})
	if err != nil {
		var nerr net.Error
		switch {
		case errors.As(err, &nerr) && nerr.Timeout():
			return nil, fmt.Errorf("%s did not answer", addr)
		case isAuthError(err):
			return nil, fmt.Errorf("%s@%s refused the password or key", host.User, host.Host)
		}
		return nil, err
	}
	return c, nil
}

func isAuthError(err error) bool {
	var se *ssh.ServerAuthError
	return errors.As(err, &se) || (err != nil && strings.Contains(err.Error(), "unable to authenticate"))
}

// handleSSHTerminalWS serves GET /api/ssh/hosts/{id}/terminal?cols=&rows=.
func (s *Server) handleSSHTerminalWS(w http.ResponseWriter, r *http.Request) {
	host, err := s.sshHosts.secrets(r.PathValue("id"))
	if errors.Is(err, errNoSSHHost) {
		writeErr(w, http.StatusNotFound, err.Error())
		return
	}
	conn, uerr := upgrader.Upgrade(w, r, nil)
	if uerr != nil {
		return
	}
	defer conn.Close()

	var writeMu sync.Mutex
	writeFrame := func(f shared.TerminalFrame) error {
		writeMu.Lock()
		defer writeMu.Unlock()
		_ = conn.SetWriteDeadline(time.Now().Add(uiWSWriteTimeout))
		return conn.WriteJSON(f)
	}
	fail := func(err error) {
		_ = writeFrame(shared.TerminalFrame{Op: shared.TermError, Error: err.Error()})
	}
	if err != nil {
		fail(err)
		return
	}

	client, err := s.sshHosts.dial(host)
	if err != nil {
		fail(err)
		return
	}
	defer client.Close()
	sess, err := client.NewSession()
	if err != nil {
		fail(err)
		return
	}
	defer sess.Close()

	cols, rows := queryInt(r, "cols", 80), queryInt(r, "rows", 24)
	modes := ssh.TerminalModes{ssh.ECHO: 1, ssh.TTY_OP_ISPEED: 38400, ssh.TTY_OP_OSPEED: 38400}
	if err := sess.RequestPty("xterm-256color", rows, cols, modes); err != nil {
		fail(err)
		return
	}
	stdin, err := sess.StdinPipe()
	if err != nil {
		fail(err)
		return
	}
	stdout, err := sess.StdoutPipe()
	if err != nil {
		fail(err)
		return
	}
	sess.Stderr = sess.Stdout
	if err := sess.Shell(); err != nil {
		fail(err)
		return
	}
	log.Printf("ssh terminal opened to %s@%s:%d", host.User, host.Host, host.Port)

	// App → server.
	go func() {
		defer sess.Close()
		for {
			var f shared.TerminalFrame
			if err := conn.ReadJSON(&f); err != nil {
				return
			}
			switch f.Op {
			case shared.TermData:
				b, err := base64.StdEncoding.DecodeString(f.Data)
				if err == nil {
					_, _ = stdin.Write(b)
				}
			case shared.TermResize:
				if f.Cols > 0 && f.Rows > 0 {
					_ = sess.WindowChange(f.Rows, f.Cols)
				}
			case shared.TermClose:
				return
			}
		}
	}()

	// A dead network otherwise leaves the tab looking connected for good.
	stopKeepAlive := make(chan struct{})
	defer close(stopKeepAlive)
	go func() {
		t := time.NewTicker(sshKeepAlive)
		defer t.Stop()
		for {
			select {
			case <-stopKeepAlive:
				return
			case <-t.C:
				if _, _, err := client.SendRequest("keepalive@openssh.com", true, nil); err != nil {
					client.Close()
					return
				}
			}
		}
	}()

	// Server → app, until the shell ends.
	buf := make([]byte, 32<<10)
	for {
		n, err := stdout.Read(buf)
		if n > 0 {
			if writeFrame(shared.TerminalFrame{Op: shared.TermData, Data: base64.StdEncoding.EncodeToString(buf[:n])}) != nil {
				return
			}
		}
		if err != nil {
			if err != io.EOF {
				fail(err)
				return
			}
			break
		}
	}
	code := 0
	var exit *ssh.ExitError
	if err := sess.Wait(); errors.As(err, &exit) {
		code = exit.ExitStatus()
	} else if err != nil {
		fail(errors.New("the connection to the server was lost"))
		return
	}
	_ = writeFrame(shared.TerminalFrame{Op: shared.TermExit, Code: code})
	writeMu.Lock()
	_ = conn.WriteControl(websocket.CloseMessage,
		websocket.FormatCloseMessage(websocket.CloseNormalClosure, ""), time.Now().Add(time.Second))
	writeMu.Unlock()
}
