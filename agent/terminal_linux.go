//go:build linux

package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	"beacle/shared"
	"github.com/creack/pty"
)

type linuxPTY struct {
	*os.File // PTY master
	cmd      *exec.Cmd
}

// loginShell picks the user's shell from /etc/passwd, then bash. Not $SHELL:
// systemd sets it to /bin/sh for root whatever passwd says, and dash in a
// terminal has no history, no arrow keys and no tab completion.
func loginShell() string {
	for _, sh := range []string{passwdShell(os.Getuid()), "/bin/bash", os.Getenv("SHELL"), "/bin/sh"} {
		if sh == "" {
			continue
		}
		if _, err := os.Stat(sh); err == nil {
			return sh
		}
	}
	return "/bin/sh"
}

// passwdShell is the login shell /etc/passwd gives uid, or "".
func passwdShell(uid int) string {
	b, err := os.ReadFile("/etc/passwd")
	if err != nil {
		return ""
	}
	return passwdShellIn(string(b), uid)
}

func passwdShellIn(passwd string, uid int) string {
	want := strconv.Itoa(uid)
	for _, line := range strings.Split(passwd, "\n") {
		f := strings.Split(strings.TrimSpace(line), ":")
		if len(f) == 7 && f[2] == want {
			// nologin and false are for service accounts, not a person at a
			// terminal.
			if strings.HasSuffix(f[6], "nologin") || strings.HasSuffix(f[6], "/false") {
				return ""
			}
			return f[6]
		}
	}
	return ""
}

// shellPath is what every shell starts with. Not inherited from the agent,
// and the same for every account: a login through the agent skips PAM, so
// /etc/environment, where Ubuntu keeps /snap/bin, is never read.
const shellPath = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin"

// loginAccount is someone a shell can be opened as.
type loginAccount struct {
	name, home, shell string
	uid, gid          int
}

// loginAccountsIn lists who a person can open a shell as: root, then the
// people's accounts (ubuntu, opc, debian, admin...) in uid order — uid from
// UID_MIN up and a shell that is not nologin. Service accounts, nobody and
// Beacle's own temporary logins are not people.
func loginAccountsIn(passwd string, uidMin int) []loginAccount {
	var root []loginAccount
	var people []loginAccount
	for _, line := range strings.Split(passwd, "\n") {
		f := strings.Split(strings.TrimSpace(line), ":")
		if len(f) != 7 || f[0] == "" {
			continue
		}
		uid, err1 := strconv.Atoi(f[2])
		gid, err2 := strconv.Atoi(f[3])
		if err1 != nil || err2 != nil {
			continue
		}
		a := loginAccount{name: f[0], uid: uid, gid: gid, home: f[5], shell: f[6]}
		switch {
		case uid == 0 && f[0] == "root":
			root = append(root, a)
		case uid < uidMin || uid >= 60000:
		case f[6] == "" || strings.HasSuffix(f[6], "nologin") || strings.HasSuffix(f[6], "/false"):
		case f[4] == tempLoginMarker && tempLoginNameRe.MatchString(f[0]):
		default:
			people = append(people, a)
		}
	}
	sort.SliceStable(people, func(i, j int) bool { return people[i].uid < people[j].uid })
	return append(root, people...)
}

// uidMin is where people's accounts start: UID_MIN from login.defs, 1000
// when it says nothing.
func uidMin() int {
	b, err := os.ReadFile("/etc/login.defs")
	if err != nil {
		return 1000
	}
	for _, line := range strings.Split(string(b), "\n") {
		f := strings.Fields(line)
		if len(f) == 2 && f[0] == "UID_MIN" {
			if v, err := strconv.Atoi(f[1]); err == nil && v > 0 {
				return v
			}
		}
	}
	return 1000
}

func loginAccounts() []loginAccount {
	b, err := os.ReadFile("/etc/passwd")
	if err != nil {
		return nil
	}
	return loginAccountsIn(string(b), uidMin())
}

// terminalUsers answers the panel's user picker. Main is the account a
// person would SSH in as — the first one that is not root.
func terminalUsers() shared.TerminalUsers {
	out := shared.TerminalUsers{Users: []string{}}
	if os.Geteuid() != 0 {
		// Only root can start a shell as someone else.
		if u, err := user.Current(); err == nil {
			out.Users = append(out.Users, u.Username)
		}
		return out
	}
	for _, a := range loginAccounts() {
		out.Users = append(out.Users, a.name)
		if out.Main == "" && a.uid != 0 {
			out.Main = a.name
		}
	}
	return out
}

// shellAccount resolves who the shell runs as. "" is the agent's own user,
// root under the shipped unit, which is what every agent before the picker
// opened.
func shellAccount(name string) (loginAccount, error) {
	self := os.Geteuid()
	if name == "" {
		u, err := user.Current()
		if err != nil {
			return loginAccount{name: "root", home: "/", shell: loginShell(), uid: self, gid: os.Getegid()}, nil
		}
		return loginAccount{name: u.Username, home: u.HomeDir, shell: loginShell(), uid: self, gid: os.Getegid()}, nil
	}
	for _, a := range loginAccounts() {
		if a.name != name {
			continue
		}
		if a.uid != self && self != 0 {
			return loginAccount{}, errors.New("the agent does not run as root, so it can only open shells as itself")
		}
		if a.uid == 0 {
			a.shell = loginShell()
		} else if _, err := os.Stat(a.shell); err != nil {
			a.shell = "/bin/bash"
		}
		return a, nil
	}
	return loginAccount{}, fmt.Errorf("there is no login account %q on this server", name)
}

// groupsOf is a's supplementary groups — sudo, docker, adm — so the shell
// can do what an SSH login as that account can.
func groupsOf(a loginAccount) []uint32 {
	gids := []uint32{uint32(a.gid)}
	u, err := user.LookupId(strconv.Itoa(a.uid))
	if err != nil {
		return gids
	}
	ids, err := u.GroupIds()
	if err != nil {
		return gids
	}
	for _, id := range ids {
		if g, err := strconv.ParseUint(id, 10, 32); err == nil && uint32(g) != uint32(a.gid) {
			gids = append(gids, uint32(g))
		}
	}
	return gids
}

func startPTY(cols, rows int, as string) (ptyProcess, error) {
	a, err := shellAccount(as)
	if err != nil {
		return nil, err
	}
	home := "/"
	if st, err := os.Stat(a.home); err == nil && st.IsDir() {
		home = a.home
	}
	cmd := exec.Command(a.shell, "-l")
	cmd.Dir = home
	// A clean login environment: the agent's own GOMEMLIMIT/GOGC must not
	// leak into whatever the user runs.
	cmd.Env = []string{
		"TERM=xterm-256color",
		"COLORTERM=truecolor",
		"HOME=" + home,
		"USER=" + a.name,
		"LOGNAME=" + a.name,
		"SHELL=" + a.shell,
		"LANG=C.UTF-8",
		"PATH=" + shellPath,
	}
	attrs := &syscall.SysProcAttr{Setsid: true, Setctty: true}
	if a.uid != os.Geteuid() {
		attrs.Credential = &syscall.Credential{Uid: uint32(a.uid), Gid: uint32(a.gid), Groups: groupsOf(a)}
	}

	// pty.StartWithAttrs, plus handing the tty to the account: sudo, tty
	// and anything else that checks who owns its terminal expect it to be
	// theirs, as it is after an SSH login.
	ptmx, tty, err := pty.Open()
	if err != nil {
		return nil, err
	}
	defer tty.Close()
	if attrs.Credential != nil {
		_ = tty.Chown(a.uid, -1)
	}
	if err := pty.Setsize(ptmx, &pty.Winsize{Cols: uint16(cols), Rows: uint16(rows)}); err != nil {
		ptmx.Close()
		return nil, err
	}
	cmd.Stdin, cmd.Stdout, cmd.Stderr = tty, tty, tty
	cmd.SysProcAttr = attrs
	if err := cmd.Start(); err != nil {
		ptmx.Close()
		return nil, err
	}
	return &linuxPTY{File: ptmx, cmd: cmd}, nil
}

func (p *linuxPTY) Resize(cols, rows int) error {
	return pty.Setsize(p.File, &pty.Winsize{Cols: uint16(cols), Rows: uint16(rows)})
}

func (p *linuxPTY) Wait() int {
	err := p.cmd.Wait()
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		return exit.ExitCode()
	}
	if err != nil {
		return -1
	}
	return 0
}

// Hangup sends SIGHUP to the shell's whole session, like closing an SSH
// connection, then SIGKILL for anything that ignored it.
func (p *linuxPTY) Hangup() {
	if p.cmd.Process == nil {
		return
	}
	pgid := p.cmd.Process.Pid // pty.Start makes the shell a session leader
	_ = syscall.Kill(-pgid, syscall.SIGHUP)
	go func() {
		time.Sleep(3 * time.Second)
		_ = syscall.Kill(-pgid, syscall.SIGKILL)
	}()
}
