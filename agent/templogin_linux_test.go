//go:build linux

package main

import (
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"beacle/shared"
)

func TestTempAccountsInOnlyTakesOurs(t *testing.T) {
	passwd := strings.Join([]string{
		"root:x:0:0:root:/root:/bin/bash",
		"beacle-a1b2c3:x:1001:1001:Beacle temporary login:/home/beacle-a1b2c3:/bin/bash",
		// Right name, someone else's account: never ours to delete.
		"beacle-ffffff:x:1002:1002:deploy bot:/home/beacle-ffffff:/bin/bash",
		// Our marker, a name the agent never makes.
		"beacle-admin:x:1003:1003:Beacle temporary login:/home/x:/bin/bash",
	}, "\n")
	got := tempAccountsIn(passwd)
	if len(got) != 1 || got[0] != "beacle-a1b2c3" {
		t.Fatalf("got %v", got)
	}
}

func TestSshdEffective(t *testing.T) {
	port, warn := sshdEffective("port 2222\nport 22\npasswordauthentication yes\nauthenticationmethods any\n")
	if port != 2222 || warn != "" {
		t.Fatalf("got %d %q", port, warn)
	}
	_, warn = sshdEffective("port 22\npasswordauthentication no\nallowusers alice\n")
	if !strings.Contains(warn, "refuses passwords") || !strings.Contains(warn, "AllowUsers") {
		t.Fatalf("warning %q", warn)
	}
	_, warn = sshdEffective("authenticationmethods publickey\npasswordauthentication yes\n")
	if !strings.Contains(warn, "publickey") {
		t.Fatalf("warning %q", warn)
	}
}

func TestSshdDropInNamesTheAccounts(t *testing.T) {
	d := sshdDropIn([]string{"beacle-a1b2c3", "beacle-0f0f0f"})
	if !strings.Contains(d, "Match User beacle-a1b2c3,beacle-0f0f0f\n") || !strings.HasSuffix(d, "Match all\n") {
		t.Fatal(d)
	}
}

func TestRandomPassword(t *testing.T) {
	a, b := randomPassword(20), randomPassword(20)
	if len(a) != 20 || a == b || strings.ContainsAny(a, "lIO01") {
		t.Fatalf("%q %q", a, b)
	}
}

// Creates and deletes a real account. Only as root in a throwaway container:
// BEACLE_ROOT_TESTS=1.
func TestTempLoginLifecycle(t *testing.T) {
	if os.Getenv("BEACLE_ROOT_TESTS") != "1" || os.Geteuid() != 0 {
		t.Skip("needs root in a throwaway container (BEACLE_ROOT_TESTS=1)")
	}
	tempLoginStatePath = filepath.Join(t.TempDir(), "logins.json")
	var sshdUsers []string
	tempLoginSshd = func(users []string) (int, string, error) {
		sshdUsers = users
		return 22, "", nil
	}
	defer func() { tempLoginSshd = configureSshd }()

	l, err := createTempLogin(shared.TempLoginRequest{Minutes: 30, Sudo: true})
	if err != nil {
		t.Fatal(err)
	}
	if l.Password == "" || !tempLoginNameRe.MatchString(l.User) || l.Port != 22 {
		t.Fatalf("login %+v", l)
	}
	if _, err := user.Lookup(l.User); err != nil {
		t.Fatalf("account missing: %v", err)
	}
	if len(sshdUsers) != 1 || sshdUsers[0] != l.User {
		t.Fatalf("sshd told %v", sshdUsers)
	}
	if got := listTempLogins(); len(got) != 1 || got[0].Password != "" {
		t.Fatalf("list %+v", got)
	}

	// Not expired yet: the reaper leaves it.
	reapTempLogins(time.Now())
	if _, err := user.Lookup(l.User); err != nil {
		t.Fatal("reaped too early")
	}
	// Past its time: gone, home and all, and sshd is told nobody is left.
	reapTempLogins(l.ExpiresAt.Add(time.Second))
	if _, err := user.Lookup(l.User); err == nil {
		t.Fatal("expired account still there")
	}
	if _, err := os.Stat("/home/" + l.User); !os.IsNotExist(err) {
		t.Fatal("home left behind")
	}
	if len(sshdUsers) != 0 || len(listTempLogins()) != 0 {
		t.Fatalf("sshd %v, list %v", sshdUsers, listTempLogins())
	}

	// Deleting by hand works the same.
	l2, err := createTempLogin(shared.TempLoginRequest{Minutes: 10})
	if err != nil {
		t.Fatal(err)
	}
	if err := deleteTempLogin(l2.User); err != nil {
		t.Fatal(err)
	}
	if _, err := user.Lookup(l2.User); err == nil {
		t.Fatal("deleted account still there")
	}
	if err := deleteTempLogin("root"); err == nil {
		t.Fatal("deleteTempLogin accepted root")
	}
}

// The whole path against a real sshd whose config refuses passwords, as on a
// cloud image: the temporary account gets in with its password and can sudo,
// root still cannot use a password. BEACLE_SSHD_TESTS=1 in a container with
// openssh-server, sudo and sshpass.
func TestTempLoginRealSshd(t *testing.T) {
	if os.Getenv("BEACLE_SSHD_TESTS") != "1" || os.Geteuid() != 0 {
		t.Skip("needs root, sshd, sudo and sshpass (BEACLE_SSHD_TESTS=1)")
	}
	tempLoginStatePath = filepath.Join(t.TempDir(), "logins.json")
	l, err := createTempLogin(shared.TempLoginRequest{Minutes: 30, Sudo: true})
	if err != nil {
		t.Fatal(err)
	}
	defer deleteTempLogin(l.User)
	if l.Warning != "" || !l.Sudo {
		t.Fatalf("login %+v", l)
	}
	sshd := exec.Command(findSshd(), "-D", "-p", "2222")
	if err := sshd.Start(); err != nil {
		t.Fatal(err)
	}
	defer sshd.Process.Kill()
	time.Sleep(time.Second)

	ssh := func(userName, pass, cmd string) (string, error) {
		out, err := exec.Command("sshpass", "-p", pass, "ssh", "-p", "2222",
			"-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
			"-o", "PreferredAuthentications=password", "-o", "PubkeyAuthentication=no",
			userName+"@127.0.0.1", cmd).CombinedOutput()
		return string(out), err
	}
	out, err := ssh(l.User, l.Password, "echo "+l.Password+" | sudo -S -p '' id -u")
	if err != nil || !strings.Contains(out, "\n0") && !strings.HasPrefix(strings.TrimSpace(out), "0") {
		t.Fatalf("temporary login: %v %q", err, out)
	}
	if _, err := exec.Command("sh", "-c", "echo root:rootpw | chpasswd").CombinedOutput(); err != nil {
		t.Fatal(err)
	}
	if out, err := ssh("root", "rootpw", "true"); err == nil {
		t.Fatalf("root got in with a password: %q", out)
	}

	if err := deleteTempLogin(l.User); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(tempLoginDropIn); !os.IsNotExist(err) {
		t.Fatal("sshd rule left behind")
	}
}
