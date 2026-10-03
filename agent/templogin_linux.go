//go:build linux

package main

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"math/big"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"beacle/shared"
)

// Temporary SSH logins: a real account for a person's own SSH client, so
// nobody is handed root's password or key. Each one lives for a set time and
// the reaper deletes the account, its home and its processes when it runs
// out.
//
// Only accounts named beacle-xxxxxx whose GECOS field is tempLoginMarker are
// ever deleted. An account the agent did not create is never touched, even
// if someone gives it a matching name.

const (
	tempLoginPrefix  = "beacle-"
	tempLoginMarker  = "Beacle temporary login"
	tempLoginDropIn  = "/etc/ssh/sshd_config.d/90-beacle-temp-logins.conf"
	tempLoginSudoers = "/etc/sudoers.d"
	tempLoginMinMins = 5
	tempLoginMaxMins = 24 * 60
)

var (
	tempLoginMu        sync.Mutex
	tempLoginNameRe    = regexp.MustCompile(`^beacle-[0-9a-f]{6}$`)
	tempLoginStatePath = "/var/lib/beacle/temp-logins.json"
	// tempLoginSshd lets exactly these accounts in with a password, or
	// removes the rule when the list is empty. Swapped out in tests.
	tempLoginSshd = configureSshd
)

func createTempLogin(req shared.TempLoginRequest) (shared.TempLogin, error) {
	if os.Geteuid() != 0 {
		return shared.TempLogin{}, errors.New("the agent does not run as root, so it cannot create accounts")
	}
	if _, err := exec.LookPath("useradd"); err != nil {
		return shared.TempLogin{}, errors.New("useradd is not available on this server")
	}
	mins := req.Minutes
	if mins <= 0 {
		mins = 60
	}
	mins = max(tempLoginMinMins, min(mins, tempLoginMaxMins))

	tempLoginMu.Lock()
	defer tempLoginMu.Unlock()

	name := ""
	for range 10 {
		n := tempLoginPrefix + randomHex(3)
		if _, err := user.Lookup(n); err != nil {
			name = n
			break
		}
	}
	if name == "" {
		return shared.TempLogin{}, errors.New("could not pick a free account name")
	}
	pass := randomPassword(20)
	expires := time.Now().Add(time.Duration(mins) * time.Minute).UTC().Truncate(time.Second)
	shell := "/bin/bash"
	if _, err := os.Stat(shell); err != nil {
		shell = "/bin/sh"
	}
	// Belt and braces: the account itself expires the day after, so it is
	// locked even if this agent never runs again.
	acctExpire := expires.Add(48 * time.Hour).Format("2006-01-02")
	if out, err := runCmd(30*time.Second, "useradd", "-m", "-s", shell, "-c", tempLoginMarker,
		"-e", acctExpire, name); err != nil {
		return shared.TempLogin{}, fmt.Errorf("useradd: %s", cmdError(out, err))
	}
	login := shared.TempLogin{User: name, Sudo: req.Sudo, ExpiresAt: expires}
	fail := func(err error) (shared.TempLogin, error) {
		deleteTempLoginLocked(name)
		return shared.TempLogin{}, err
	}

	cmd := exec.Command("chpasswd")
	cmd.Stdin = strings.NewReader(name + ":" + pass + "\n")
	if out, err := cmd.CombinedOutput(); err != nil {
		return fail(fmt.Errorf("chpasswd: %s", cmdError(string(out), err)))
	}
	var warnings []string
	if req.Sudo {
		if err := writeTempSudoers(name); err != nil {
			login.Sudo = false
			warnings = append(warnings, "no sudo for this account: "+err.Error())
		}
	}

	logins := append(loadTempLogins(), login)
	if err := saveTempLogins(logins); err != nil {
		return fail(err)
	}
	port, warning, err := tempLoginSshd(tempLoginUsers(logins))
	if err != nil {
		return fail(err)
	}
	if warning != "" {
		warnings = append(warnings, warning)
	}
	login.Port = port
	login.Warning = strings.Join(warnings, " ")
	login.Password = pass
	log.Printf("temporary ssh login %s created (sudo %v), expires %s", name, login.Sudo, expires.Format(time.RFC3339))
	return login, nil
}

func listTempLogins() []shared.TempLogin {
	tempLoginMu.Lock()
	defer tempLoginMu.Unlock()
	return loadTempLogins()
}

func deleteTempLogin(name string) error {
	if !tempLoginNameRe.MatchString(name) {
		return errors.New("not a temporary login")
	}
	tempLoginMu.Lock()
	defer tempLoginMu.Unlock()
	deleteTempLoginLocked(name)
	log.Printf("temporary ssh login %s deleted", name)
	return nil
}

func deleteTempLoginLocked(name string) {
	removeTempAccount(name)
	var keep []shared.TempLogin
	for _, l := range loadTempLogins() {
		if l.User != name {
			keep = append(keep, l)
		}
	}
	_ = saveTempLogins(keep)
	if _, _, err := tempLoginSshd(tempLoginUsers(keep)); err != nil {
		log.Printf("temporary logins: sshd: %v", err)
	}
}

// tempLoginReaper deletes logins as they expire, and accounts the agent made
// whose record is gone (a state file lost with a crash).
func tempLoginReaper() {
	reapTempLogins(time.Now())
	t := time.NewTicker(30 * time.Second)
	defer t.Stop()
	for now := range t.C {
		reapTempLogins(now)
	}
}

func reapTempLogins(now time.Time) {
	tempLoginMu.Lock()
	defer tempLoginMu.Unlock()
	logins := loadTempLogins()
	var keep []shared.TempLogin
	known := map[string]bool{}
	for _, l := range logins {
		if now.After(l.ExpiresAt) {
			removeTempAccount(l.User)
			log.Printf("temporary ssh login %s expired and was deleted", l.User)
			continue
		}
		keep = append(keep, l)
		known[l.User] = true
	}
	orphans := false
	if b, err := os.ReadFile("/etc/passwd"); err == nil {
		for _, n := range tempAccountsIn(string(b)) {
			if !known[n] {
				removeTempAccount(n)
				orphans = true
				log.Printf("temporary ssh login %s had no record and was deleted", n)
			}
		}
	}
	if len(keep) == len(logins) && !orphans {
		// Nothing changed; still make sure a stale sshd rule is not left
		// behind with no account to serve.
		if len(keep) == 0 {
			if _, err := os.Stat(tempLoginDropIn); err == nil {
				_, _, _ = tempLoginSshd(nil)
			}
		}
		return
	}
	_ = saveTempLogins(keep)
	if _, _, err := tempLoginSshd(tempLoginUsers(keep)); err != nil {
		log.Printf("temporary logins: sshd: %v", err)
	}
}

// removeTempAccount kills the account's processes and deletes it with its
// home — only if it is one the agent created.
func removeTempAccount(name string) {
	if !tempLoginNameRe.MatchString(name) {
		return
	}
	_ = os.Remove(filepath.Join(tempLoginSudoers, name))
	b, err := os.ReadFile("/etc/passwd")
	if err != nil || !containsString(tempAccountsIn(string(b)), name) {
		return
	}
	_, _ = runCmd(10*time.Second, "pkill", "-KILL", "-u", name)
	time.Sleep(200 * time.Millisecond)
	// userdel exits 12 when there was no mail spool to remove; the account is
	// gone all the same.
	if out, err := runCmd(30*time.Second, "userdel", "-f", "-r", name); err != nil {
		if b, rerr := os.ReadFile("/etc/passwd"); rerr == nil && containsString(tempAccountsIn(string(b)), name) {
			log.Printf("temporary logins: userdel %s: %s", name, cmdError(out, err))
		}
	}
}

// tempAccountsIn lists the accounts in a passwd file that the agent created.
func tempAccountsIn(passwd string) []string {
	var out []string
	for _, line := range strings.Split(passwd, "\n") {
		f := strings.Split(strings.TrimSpace(line), ":")
		if len(f) == 7 && tempLoginNameRe.MatchString(f[0]) && f[4] == tempLoginMarker {
			out = append(out, f[0])
		}
	}
	return out
}

func writeTempSudoers(name string) error {
	if _, err := exec.LookPath("sudo"); err != nil {
		return errors.New("sudo is not installed")
	}
	if st, err := os.Stat(tempLoginSudoers); err != nil || !st.IsDir() {
		return errors.New("there is no /etc/sudoers.d")
	}
	// The password is the login's own; sudo asks for it, as on any account.
	content := name + " ALL=(ALL:ALL) ALL\n"
	if visudo, err := exec.LookPath("visudo"); err == nil {
		tmp, err := os.CreateTemp("", "beacle-sudoers-*")
		if err != nil {
			return err
		}
		defer os.Remove(tmp.Name())
		_, _ = tmp.WriteString(content)
		tmp.Close()
		if out, err := runCmd(10*time.Second, visudo, "-cf", tmp.Name()); err != nil {
			return fmt.Errorf("visudo: %s", cmdError(out, err))
		}
	}
	return os.WriteFile(filepath.Join(tempLoginSudoers, name), []byte(content), 0o440)
}

// --- sshd ---------------------------------------------------------------

// sshdDropIn lets exactly these accounts log in with a password. Everything
// else keeps whatever the server's own config says.
func sshdDropIn(users []string) string {
	return "# Written by the Beacle agent while temporary SSH logins exist, and\n" +
		"# removed with the last of them. Lets only those accounts in with a password.\n" +
		"Match User " + strings.Join(users, ",") + "\n" +
		"\tPasswordAuthentication yes\n" +
		"Match all\n"
}

func findSshd() string {
	if p, err := exec.LookPath("sshd"); err == nil {
		return p
	}
	for _, p := range []string{"/usr/sbin/sshd", "/usr/local/sbin/sshd"} {
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	return ""
}

func configureSshd(users []string) (port int, warning string, err error) {
	if len(users) == 0 {
		if os.Remove(tempLoginDropIn) == nil {
			reloadSshd()
		}
		return 0, "", nil
	}
	sshd := findSshd()
	if sshd == "" {
		return 0, "", errors.New("there is no SSH server on this machine — install openssh-server")
	}
	if err := os.MkdirAll(filepath.Dir(tempLoginDropIn), 0o755); err != nil {
		return 0, "", err
	}
	want := []byte(sshdDropIn(users))
	if old, _ := os.ReadFile(tempLoginDropIn); !bytes.Equal(old, want) {
		if err := os.WriteFile(tempLoginDropIn, want, 0o644); err != nil {
			return 0, "", err
		}
		// Never reload a config sshd would refuse: a broken sshd_config
		// locks everyone out of the server.
		if out, err := runCmd(15*time.Second, sshd, "-t"); err != nil {
			_ = os.Remove(tempLoginDropIn)
			return 0, "", fmt.Errorf("sshd refused the config: %s", cmdError(out, err))
		}
		reloadSshd()
	}
	out, err := runCmd(15*time.Second, sshd, "-T", "-C",
		"user="+users[len(users)-1]+",host=localhost,addr=127.0.0.1")
	if err != nil {
		return 22, "", nil // could not ask; the login most likely works on 22
	}
	port, warning = sshdEffective(out)
	return port, warning, nil
}

// reloadSshd makes a running sshd reread its config. A socket-activated one
// that is not running reads it when the next connection starts it.
func reloadSshd() {
	for _, unit := range []string{"ssh.service", "sshd.service"} {
		_, _ = runCmd(15*time.Second, "systemctl", "try-reload-or-restart", unit)
	}
}

// sshdEffective reads `sshd -T -C user=…` for the port and anything that
// would still turn the login away.
func sshdEffective(out string) (port int, warning string) {
	port = 22
	var warns []string
	gotPort := false
	for _, line := range strings.Split(out, "\n") {
		f := strings.Fields(line)
		if len(f) < 2 {
			continue
		}
		switch strings.ToLower(f[0]) {
		case "port":
			if p, err := strconv.Atoi(f[1]); err == nil && !gotPort {
				port, gotPort = p, true
			}
		case "passwordauthentication":
			if f[1] != "yes" {
				warns = append(warns, "sshd still refuses passwords for this account (its config may not include /etc/ssh/sshd_config.d).")
			}
		case "allowusers":
			warns = append(warns, "sshd only lets in the users listed in AllowUsers, and this account is not one of them.")
		case "allowgroups":
			warns = append(warns, "sshd only lets in the groups listed in AllowGroups.")
		case "authenticationmethods":
			if f[1] != "any" && !strings.Contains(f[1], "password") {
				warns = append(warns, "sshd requires "+f[1]+" logins, so a password alone will not do.")
			}
		}
	}
	return port, strings.Join(warns, " ")
}

// --- state --------------------------------------------------------------

func loadTempLogins() []shared.TempLogin {
	out := []shared.TempLogin{}
	b, err := os.ReadFile(tempLoginStatePath)
	if err != nil {
		return out
	}
	_ = json.Unmarshal(b, &out)
	for i := range out {
		out[i].Password = "" // never stored, but never handed out either
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ExpiresAt.Before(out[j].ExpiresAt) })
	return out
}

func saveTempLogins(logins []shared.TempLogin) error {
	if logins == nil {
		logins = []shared.TempLogin{}
	}
	for i := range logins {
		logins[i].Password = ""
	}
	b, err := json.MarshalIndent(logins, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(tempLoginStatePath), 0o700); err != nil {
		return err
	}
	tmp := tempLoginStatePath + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, tempLoginStatePath)
}

func tempLoginUsers(logins []shared.TempLogin) []string {
	var out []string
	for _, l := range logins {
		out = append(out, l.User)
	}
	return out
}

// --- helpers ------------------------------------------------------------

func randomHex(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// randomPassword leaves out characters that are easy to misread.
func randomPassword(n int) string {
	const alphabet = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	var sb strings.Builder
	for range n {
		i, _ := rand.Int(rand.Reader, big.NewInt(int64(len(alphabet))))
		sb.WriteByte(alphabet[i.Int64()])
	}
	return sb.String()
}

func cmdError(out string, err error) string {
	s := strings.TrimSpace(out)
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		s = s[:i]
	}
	if s == "" && err != nil {
		s = err.Error()
	}
	return s
}

func containsString(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}
	return false
}
