package main

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

// Updater implements agent self-update with rollback. The binary is replaced
// atomically; the previous binary is kept in versions/. The config file is
// never touched.
type Updater struct {
	cfg *Config
}

func NewUpdater(cfg *Config) *Updater { return &Updater{cfg: cfg} }

func (u *Updater) binPath() (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	return filepath.EvalSymlinks(exe)
}

func (u *Updater) prevPath(bin string) string {
	dir := filepath.Join(filepath.Dir(bin), "versions")
	_ = os.MkdirAll(dir, 0o755)
	return filepath.Join(dir, "beacle-agent.prev")
}

// remoteVersion asks the backend which agent version it distributes.
func (u *Updater) remoteVersion() (string, error) {
	resp, err := http.Get(u.cfg.BackendURL + "/download/agent/version")
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	s := string(b)
	if i := strings.Index(s, `"version"`); i >= 0 {
		s = s[i+9:]
		s = strings.Trim(strings.Trim(strings.TrimSpace(strings.Trim(strings.TrimSpace(s), ":")), `"}`+"\n"), `"`)
		return strings.TrimSpace(s), nil
	}
	return "", fmt.Errorf("no version in response")
}

// Update downloads the latest binary from the backend and restarts the agent.
func (u *Updater) Update() (string, error) {
	remote, err := u.remoteVersion()
	if err != nil {
		return "", fmt.Errorf("check version: %w", err)
	}
	if remote == AgentVersion {
		return "already up to date (" + AgentVersion + ")", nil
	}
	bin, err := u.binPath()
	if err != nil {
		return "", err
	}
	url := fmt.Sprintf("%s/download/agent?arch=%s", u.cfg.BackendURL, runtime.GOARCH)
	resp, err := http.Get(url)
	if err != nil {
		return "", fmt.Errorf("download: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("download failed: HTTP %d", resp.StatusCode)
	}
	tmp := bin + ".new"
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o755)
	if err != nil {
		return "", err
	}
	if _, err := io.Copy(f, resp.Body); err != nil {
		f.Close()
		return "", err
	}
	f.Close()

	// preserve current binary for rollback, then swap atomically
	if err := copyFile(bin, u.prevPath(bin)); err != nil {
		return "", fmt.Errorf("backup current binary: %w", err)
	}
	if err := os.Rename(tmp, bin); err != nil {
		return "", fmt.Errorf("swap binary: %w", err)
	}
	u.restartSoon()
	return fmt.Sprintf("updated %s -> %s, restarting", AgentVersion, remote), nil
}

// Rollback restores the previous binary and restarts.
func (u *Updater) Rollback() (string, error) {
	bin, err := u.binPath()
	if err != nil {
		return "", err
	}
	prev := u.prevPath(bin)
	if _, err := os.Stat(prev); err != nil {
		return "", fmt.Errorf("no previous version available")
	}
	if err := copyFile(prev, bin+".new"); err != nil {
		return "", err
	}
	_ = os.Chmod(bin+".new", 0o755)
	if err := os.Rename(bin+".new", bin); err != nil {
		return "", err
	}
	u.restartSoon()
	return "rolled back to previous version, restarting", nil
}

// restartSoon lets the HTTP response flush, then exits; systemd restarts us
// with the new binary (Restart=always).
func (u *Updater) restartSoon() {
	go func() {
		time.Sleep(500 * time.Millisecond)
		if runtime.GOOS == "linux" {
			// prefer a clean systemd restart when running as a service
			if err := exec.Command("systemctl", "restart", "beacle-agent").Start(); err == nil {
				return
			}
		}
		os.Exit(0)
	}()
}

// AutoUpdateLoop checks the backend for a newer agent every 6 hours.
func (u *Updater) AutoUpdateLoop() {
	for range time.Tick(6 * time.Hour) {
		remote, err := u.remoteVersion()
		if err != nil || remote == "" || remote == "0.0.0" || remote == AgentVersion {
			continue
		}
		if _, err := u.Update(); err == nil {
			return // process restarts
		}
	}
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(dst, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o755)
	if err != nil {
		return err
	}
	defer out.Close()
	_, err = io.Copy(out, in)
	return err
}
