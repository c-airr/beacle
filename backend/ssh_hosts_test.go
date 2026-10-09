package main

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"encoding/pem"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"

	"beacle/shared"
	"github.com/gorilla/websocket"
	"golang.org/x/crypto/ssh"
)

// fakeSSHServer accepts user/password (or the key in authorized, if any),
// opens a PTY session and echoes what is typed back as "echo:<line>". It
// returns host and port.
func fakeSSHServer(t *testing.T, password string, authorized ssh.PublicKey) (string, int) {
	t.Helper()
	_, hostPriv, _ := ed25519.GenerateKey(rand.Reader)
	hostSigner, err := ssh.NewSignerFromKey(hostPriv)
	if err != nil {
		t.Fatal(err)
	}
	cfg := &ssh.ServerConfig{
		PasswordCallback: func(c ssh.ConnMetadata, pw []byte) (*ssh.Permissions, error) {
			if c.User() == "tester" && string(pw) == password {
				return nil, nil
			}
			return nil, errAuth
		},
		PublicKeyCallback: func(c ssh.ConnMetadata, k ssh.PublicKey) (*ssh.Permissions, error) {
			if authorized != nil && bytes.Equal(k.Marshal(), authorized.Marshal()) {
				return nil, nil
			}
			return nil, errAuth
		},
	}
	cfg.AddHostKey(hostSigner)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			nc, err := ln.Accept()
			if err != nil {
				return
			}
			go serveFakeSSH(nc, cfg)
		}
	}()
	addr := ln.Addr().(*net.TCPAddr)
	return "127.0.0.1", addr.Port
}

var errAuth = errors.New("denied")

func serveFakeSSH(nc net.Conn, cfg *ssh.ServerConfig) {
	_, chans, reqs, err := ssh.NewServerConn(nc, cfg)
	if err != nil {
		return
	}
	go ssh.DiscardRequests(reqs)
	for nch := range chans {
		ch, chReqs, err := nch.Accept()
		if err != nil {
			continue
		}
		go func() {
			for req := range chReqs {
				switch req.Type {
				case "pty-req":
					// term string, cols, rows
					n := binary.BigEndian.Uint32(req.Payload)
					cols := binary.BigEndian.Uint32(req.Payload[4+n:])
					req.Reply(true, nil)
					ch.Write([]byte("cols=" + strconv.Itoa(int(cols)) + "\r\n"))
				case "shell":
					req.Reply(true, nil)
					go func() {
						buf := make([]byte, 256)
						var line []byte
						for {
							n, err := ch.Read(buf)
							if err != nil {
								return
							}
							for _, c := range buf[:n] {
								if c != '\r' {
									line = append(line, c)
									continue
								}
								if string(line) == "exit" {
									ch.SendRequest("exit-status", false, binary.BigEndian.AppendUint32(nil, 3))
									ch.Close()
									return
								}
								ch.Write([]byte("echo:" + string(line) + "\r\n"))
								line = line[:0]
							}
						}
					}()
				default:
					req.Reply(false, nil)
				}
			}
		}()
	}
}

func sshTestServer(t *testing.T) (*Server, *httptest.Server) {
	t.Helper()
	s := &Server{sshHosts: NewSSHHosts(t.TempDir())}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/ssh/hosts/{id}/terminal", s.handleSSHTerminalWS)
	ts := httptest.NewServer(mux)
	t.Cleanup(ts.Close)
	return s, ts
}

func openSSHTerminal(t *testing.T, ts *httptest.Server, id string) *websocket.Conn {
	t.Helper()
	url := "ws" + strings.TrimPrefix(ts.URL, "http") + "/api/ssh/hosts/" + id + "/terminal?cols=120&rows=40"
	c, _, err := websocket.DefaultDialer.Dial(url, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	return c
}

// readUntil collects terminal output until it contains want, or an error or
// exit frame arrives.
func readUntil(t *testing.T, c *websocket.Conn, want string) (string, shared.TerminalFrame) {
	t.Helper()
	var out strings.Builder
	_ = c.SetReadDeadline(time.Now().Add(5 * time.Second))
	for {
		var f shared.TerminalFrame
		if err := c.ReadJSON(&f); err != nil {
			t.Fatalf("reading terminal (got %q so far): %v", out.String(), err)
		}
		if f.Op != shared.TermData {
			return out.String(), f
		}
		b, _ := base64.StdEncoding.DecodeString(f.Data)
		out.Write(b)
		if want != "" && strings.Contains(out.String(), want) {
			return out.String(), f
		}
	}
}

func typeLine(t *testing.T, c *websocket.Conn, line string) {
	t.Helper()
	if err := c.WriteJSON(shared.TerminalFrame{Op: shared.TermData, Data: base64.StdEncoding.EncodeToString([]byte(line + "\r"))}); err != nil {
		t.Fatal(err)
	}
}

func TestSSHHostWithPasswordRunsAShellAndReportsTheExit(t *testing.T) {
	host, port := fakeSSHServer(t, "hunter2", nil)
	s, ts := sshTestServer(t)
	v, err := s.sshHosts.Create(SSHHostInput{Host: host, Port: port, User: "tester", Password: "hunter2"})
	if err != nil {
		t.Fatal(err)
	}
	if !v.HasPassword || v.HasKey || v.Label != host {
		t.Fatalf("view = %+v", v)
	}

	c := openSSHTerminal(t, ts, v.ID)
	readUntil(t, c, "cols=120")
	typeLine(t, c, "ls -la")
	readUntil(t, c, "echo:ls -la")
	typeLine(t, c, "exit")
	_, last := readUntil(t, c, "")
	if last.Op != shared.TermExit || last.Code != 3 {
		t.Fatalf("last frame = %+v, want exit 3", last)
	}

	// The host key was learnt on the way in.
	known, _ := os.ReadFile(s.sshHosts.knownPath)
	if !strings.Contains(string(known), "ssh-ed25519") {
		t.Fatalf("known_hosts = %q", known)
	}
}

func TestSSHHostWithKeyLogsIn(t *testing.T) {
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	block, err := ssh.MarshalPrivateKeyWithPassphrase(priv, "", []byte("open sesame"))
	if err != nil {
		t.Fatal(err)
	}
	sshPub, _ := ssh.NewPublicKey(pub)
	host, port := fakeSSHServer(t, "", sshPub)
	s, ts := sshTestServer(t)
	key := string(pem.EncodeToMemory(block))

	if _, err := s.sshHosts.Create(SSHHostInput{Host: host, Port: port, User: "tester", Key: key}); err == nil ||
		!strings.Contains(err.Error(), "passphrase") {
		t.Fatalf("a protected key without its passphrase: err = %v", err)
	}
	if _, err := s.sshHosts.Create(SSHHostInput{Host: host, Port: port, User: "tester", Key: key, Passphrase: "nope"}); err == nil ||
		!strings.Contains(err.Error(), "wrong") {
		t.Fatalf("a wrong passphrase: err = %v", err)
	}
	v, err := s.sshHosts.Create(SSHHostInput{Label: "box", Host: host, Port: port, User: "tester", Key: key, Passphrase: "open sesame"})
	if err != nil {
		t.Fatal(err)
	}
	c := openSSHTerminal(t, ts, v.ID)
	readUntil(t, c, "cols=120")
}

func TestSSHWrongPasswordIsReportedNotHung(t *testing.T) {
	host, port := fakeSSHServer(t, "right", nil)
	s, ts := sshTestServer(t)
	v, _ := s.sshHosts.Create(SSHHostInput{Host: host, Port: port, User: "tester", Password: "wrong"})
	c := openSSHTerminal(t, ts, v.ID)
	_, f := readUntil(t, c, "")
	if f.Op != shared.TermError || !strings.Contains(f.Error, "refused") {
		t.Fatalf("frame = %+v", f)
	}
}

func TestSSHChangedHostKeyIsRefused(t *testing.T) {
	host, port := fakeSSHServer(t, "pw", nil)
	s, ts := sshTestServer(t)
	v, _ := s.sshHosts.Create(SSHHostInput{Host: host, Port: port, User: "tester", Password: "pw"})
	// Someone else's key on record for this address.
	_, other, _ := ed25519.GenerateKey(rand.Reader)
	otherSigner, _ := ssh.NewSignerFromKey(other)
	line := "[127.0.0.1]:" + strconv.Itoa(port) + " " + string(bytes.TrimSpace(ssh.MarshalAuthorizedKey(otherSigner.PublicKey())))
	_ = os.WriteFile(s.sshHosts.knownPath, []byte(line+"\n"), 0o600)

	c := openSSHTerminal(t, ts, v.ID)
	_, f := readUntil(t, c, "")
	if f.Op != shared.TermError || !strings.Contains(f.Error, "host key") {
		t.Fatalf("frame = %+v", f)
	}
}

func TestSSHHostSecretsStayInTheBackend(t *testing.T) {
	dir := t.TempDir()
	h := NewSSHHosts(dir)
	v, err := h.Create(SSHHostInput{Label: "web", Host: "example.com", User: "deploy", Password: "s3cret-pw"})
	if err != nil {
		t.Fatal(err)
	}
	if v.Port != 22 {
		t.Fatalf("default port = %d", v.Port)
	}
	raw, _ := os.ReadFile(dir + "/ssh_hosts.json")
	if runtime.GOOS == "windows" && strings.Contains(string(raw), "s3cret-pw") {
		t.Fatal("the password is stored in the clear")
	}

	// An edit with no password keeps it; reloading reads it back.
	if _, err := h.Update(v.ID, SSHHostInput{Label: "web2", Host: "example.com", User: "deploy"}); err != nil {
		t.Fatal(err)
	}
	got, err := NewSSHHosts(dir).secrets(v.ID)
	if err != nil || got.Password != "s3cret-pw" || got.Label != "web2" {
		t.Fatalf("after reload: %+v, %v", got, err)
	}
	if _, err := h.Update(v.ID, SSHHostInput{Host: "example.com", User: "deploy", ClearPassword: true}); err != nil {
		t.Fatal(err)
	}
	if l := h.List(); len(l) != 1 || l[0].HasPassword {
		t.Fatalf("after clearing: %+v", l)
	}

	for _, bad := range []SSHHostInput{
		{Host: "", User: "x"},
		{Host: "a b", User: "x"},
		{Host: "h", User: ""},
		{Host: "h", User: "x", Port: 70000},
		{Host: "h", User: "x", Key: "ssh-ed25519 AAAA... a public key"},
	} {
		if _, err := h.Create(bad); err == nil {
			t.Errorf("Create(%+v) accepted", bad)
		}
	}
	if !h.Delete(v.ID) || h.Delete(v.ID) {
		t.Fatal("delete")
	}
}
