package main

import (
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/ssh"
)

// Saved SSH hosts: machines the SSH tab reaches with an ordinary SSH client
// from this computer — host, port, user, password or private key — rather
// than through a Beacle agent. They live in ssh_hosts.json next to the rest
// of the backend's data; passwords, keys and passphrases are sealed (DPAPI on
// Windows) and never leave the backend: the app only learns whether one is
// set.

const sealedPrefix = "dpapi:"

var errSealed = errors.New("a saved secret could not be decrypted on this account — enter it again")

// sshHostRecord is one host as stored, secrets sealed.
type sshHostRecord struct {
	ID         string    `json:"id"`
	Label      string    `json:"label"`
	Host       string    `json:"host"`
	Port       int       `json:"port"`
	User       string    `json:"user"`
	Password   string    `json:"password,omitempty"`
	Key        string    `json:"key,omitempty"`
	Passphrase string    `json:"passphrase,omitempty"`
	CreatedAt  time.Time `json:"created_at"`
}

// SSHHostView is what the app sees of a host.
type SSHHostView struct {
	ID          string `json:"id"`
	Label       string `json:"label"`
	Host        string `json:"host"`
	Port        int    `json:"port"`
	User        string `json:"user"`
	HasPassword bool   `json:"has_password"`
	HasKey      bool   `json:"has_key"`
}

func (r *sshHostRecord) view() SSHHostView {
	return SSHHostView{ID: r.ID, Label: r.Label, Host: r.Host, Port: r.Port, User: r.User,
		HasPassword: r.Password != "", HasKey: r.Key != ""}
}

// SSHHostInput is a create or an edit from the app. On an edit an empty
// secret keeps the saved one; Clear* removes it.
type SSHHostInput struct {
	Label         string `json:"label"`
	Host          string `json:"host"`
	Port          int    `json:"port"`
	User          string `json:"user"`
	Password      string `json:"password"`
	Key           string `json:"key"`
	Passphrase    string `json:"passphrase"`
	ClearPassword bool   `json:"clear_password"`
	ClearKey      bool   `json:"clear_key"`
}

var (
	sshHostRe = regexp.MustCompile(`^[A-Za-z0-9.:\[\]_-]{1,253}$`)
	sshUserRe = regexp.MustCompile(`^[A-Za-z0-9_][A-Za-z0-9_.@-]{0,63}$`)
)

type SSHHosts struct {
	path      string
	knownPath string

	mu    sync.Mutex
	hosts []*sshHostRecord
}

func NewSSHHosts(dataDir string) *SSHHosts {
	h := &SSHHosts{
		path:      filepath.Join(dataDir, "ssh_hosts.json"),
		knownPath: filepath.Join(dataDir, "known_hosts"),
	}
	if b, err := os.ReadFile(h.path); err == nil {
		_ = json.Unmarshal(b, &h.hosts)
	}
	return h
}

func (h *SSHHosts) saveLocked() error {
	b, err := json.MarshalIndent(h.hosts, "", "  ")
	if err != nil {
		return err
	}
	tmp := h.path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, h.path)
}

func (h *SSHHosts) List() []SSHHostView {
	h.mu.Lock()
	defer h.mu.Unlock()
	out := make([]SSHHostView, 0, len(h.hosts))
	for _, r := range h.hosts {
		out = append(out, r.view())
	}
	sort.SliceStable(out, func(i, j int) bool { return strings.ToLower(out[i].Label) < strings.ToLower(out[j].Label) })
	return out
}

// checkInput normalises in and says what is wrong with it, if anything.
func checkInput(in *SSHHostInput) error {
	in.Label = strings.TrimSpace(in.Label)
	in.Host = strings.TrimSpace(in.Host)
	in.User = strings.TrimSpace(in.User)
	in.Key = strings.TrimSpace(in.Key)
	if in.Port == 0 {
		in.Port = 22
	}
	switch {
	case !sshHostRe.MatchString(in.Host):
		return errors.New("enter the host as a name or an IP address")
	case in.Port < 1 || in.Port > 65535:
		return errors.New("the port must be between 1 and 65535")
	case !sshUserRe.MatchString(in.User):
		return errors.New("enter the user name to log in as")
	case len(in.Label) > 64:
		return errors.New("the name is too long")
	case len(in.Password) > 1024 || len(in.Passphrase) > 1024 || len(in.Key) > 64<<10:
		return errors.New("a password or key is too long")
	}
	if in.Label == "" {
		in.Label = in.Host
	}
	if in.Key != "" {
		if _, err := parseKey(in.Key, in.Passphrase); err != nil {
			return err
		}
	}
	return nil
}

// parseKey reads a private key the way dialling will, so a wrong passphrase
// or a public key pasted by mistake is caught when saving, not at login.
func parseKey(pem, passphrase string) (ssh.Signer, error) {
	var signer ssh.Signer
	var err error
	if passphrase != "" {
		signer, err = ssh.ParsePrivateKeyWithPassphrase([]byte(pem), []byte(passphrase))
	} else {
		signer, err = ssh.ParsePrivateKey([]byte(pem))
	}
	var missing *ssh.PassphraseMissingError
	switch {
	case errors.As(err, &missing):
		return nil, errors.New("this key is protected — enter its passphrase")
	case errors.Is(err, x509.IncorrectPasswordError):
		return nil, errors.New("the key's passphrase is wrong")
	case err != nil:
		return nil, fmt.Errorf("this is not a private key Beacle can read (OpenSSH, PEM or PKCS#8): %v", err)
	}
	return signer, nil
}

func (h *SSHHosts) Create(in SSHHostInput) (SSHHostView, error) {
	if err := checkInput(&in); err != nil {
		return SSHHostView{}, err
	}
	r := &sshHostRecord{ID: newID(), Label: in.Label, Host: in.Host, Port: in.Port, User: in.User, CreatedAt: time.Now().UTC()}
	if err := r.setSecrets(in); err != nil {
		return SSHHostView{}, err
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	h.hosts = append(h.hosts, r)
	if err := h.saveLocked(); err != nil {
		h.hosts = h.hosts[:len(h.hosts)-1]
		return SSHHostView{}, err
	}
	return r.view(), nil
}

func (h *SSHHosts) Update(id string, in SSHHostInput) (SSHHostView, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	var r *sshHostRecord
	for _, x := range h.hosts {
		if x.ID == id {
			r = x
		}
	}
	if r == nil {
		return SSHHostView{}, errNoSSHHost
	}
	// A key kept as it is still has to unlock with the passphrase given now.
	if in.Key == "" && !in.ClearKey && r.Key != "" && in.Passphrase != "" {
		key, err := unseal(r.Key)
		if err != nil {
			return SSHHostView{}, err
		}
		in.Key = key
	}
	if err := checkInput(&in); err != nil {
		return SSHHostView{}, err
	}
	next := *r
	next.Label, next.Host, next.Port, next.User = in.Label, in.Host, in.Port, in.User
	if err := next.setSecrets(in); err != nil {
		return SSHHostView{}, err
	}
	prev := *r
	*r = next
	if err := h.saveLocked(); err != nil {
		*r = prev
		return SSHHostView{}, err
	}
	return r.view(), nil
}

// setSecrets seals what in brings and drops what it clears.
func (r *sshHostRecord) setSecrets(in SSHHostInput) error {
	if in.ClearPassword {
		r.Password = ""
	}
	if in.ClearKey {
		r.Key, r.Passphrase = "", ""
	}
	if in.Password != "" {
		s, err := seal(in.Password)
		if err != nil {
			return err
		}
		r.Password = s
	}
	if in.Key != "" {
		k, err := seal(in.Key)
		if err != nil {
			return err
		}
		p, err := seal(in.Passphrase)
		if err != nil {
			return err
		}
		r.Key, r.Passphrase = k, p
	}
	return nil
}

var errNoSSHHost = errors.New("ssh host not found")

func (h *SSHHosts) Delete(id string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	for i, r := range h.hosts {
		if r.ID == id {
			h.hosts = append(h.hosts[:i], h.hosts[i+1:]...)
			_ = h.saveLocked()
			return true
		}
	}
	return false
}

// secrets returns host id with its secrets decrypted.
func (h *SSHHosts) secrets(id string) (*sshHostRecord, error) {
	h.mu.Lock()
	var rec *sshHostRecord
	for _, r := range h.hosts {
		if r.ID == id {
			c := *r
			rec = &c
		}
	}
	h.mu.Unlock()
	if rec == nil {
		return nil, errNoSSHHost
	}
	var err error
	for _, f := range []*string{&rec.Password, &rec.Key, &rec.Passphrase} {
		if *f, err = unseal(*f); err != nil {
			return nil, err
		}
	}
	return rec, nil
}

// ---------------------------------------------------------------------------
// API: /api/ssh/hosts
// ---------------------------------------------------------------------------

func (s *Server) handleListSSHHosts(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, s.sshHosts.List())
}

func (s *Server) handleCreateSSHHost(w http.ResponseWriter, r *http.Request) {
	var in SSHHostInput
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 128<<10)).Decode(&in); err != nil {
		writeErr(w, http.StatusBadRequest, "bad json")
		return
	}
	v, err := s.sshHosts.Create(in)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusCreated, v)
}

func (s *Server) handleUpdateSSHHost(w http.ResponseWriter, r *http.Request) {
	var in SSHHostInput
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 128<<10)).Decode(&in); err != nil {
		writeErr(w, http.StatusBadRequest, "bad json")
		return
	}
	v, err := s.sshHosts.Update(r.PathValue("id"), in)
	switch {
	case errors.Is(err, errNoSSHHost):
		writeErr(w, http.StatusNotFound, err.Error())
	case err != nil:
		writeErr(w, http.StatusBadRequest, err.Error())
	default:
		writeJSON(w, http.StatusOK, v)
	}
}

func (s *Server) handleDeleteSSHHost(w http.ResponseWriter, r *http.Request) {
	if !s.sshHosts.Delete(r.PathValue("id")) {
		writeErr(w, http.StatusNotFound, errNoSSHHost.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}
