package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"time"

	"beacle/shared"
)

// Updater implements agent self-update with rollback. Binaries come from the
// public GitHub release (agentbeta). Config is never touched.
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

func (u *Updater) versionsDir(bin string) string {
	dir := filepath.Join(filepath.Dir(bin), "versions")
	_ = os.MkdirAll(dir, 0o755)
	return dir
}

func (u *Updater) prevPath(bin string) string {
	return filepath.Join(u.versionsDir(bin), "beacle-agent.prev")
}

func (u *Updater) stampPath(bin string) string {
	return filepath.Join(u.versionsDir(bin), "github.stamp")
}

type githubRelease struct {
	PublishedAt string `json:"published_at"`
	Assets      []struct {
		Name               string `json:"name"`
		UpdatedAt          string `json:"updated_at"`
		BrowserDownloadURL string `json:"browser_download_url"`
		Digest             string `json:"digest"`
	} `json:"assets"`
}

func fetchGitHubAsset(goarch string) (stamp, downloadURL string, err error) {
	req, err := http.NewRequest(http.MethodGet, shared.AgentGitHubReleaseAPI(), nil)
	if err != nil {
		return "", "", err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", "beacle-agent/"+AgentVersion)

	client := &http.Client{Timeout: 20 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return "", "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", "", fmt.Errorf("github release HTTP %d", resp.StatusCode)
	}
	var rel githubRelease
	if err := json.NewDecoder(resp.Body).Decode(&rel); err != nil {
		return "", "", err
	}
	want := shared.AgentGitHubAssetName(goarch)
	for _, a := range rel.Assets {
		if a.Name != want {
			continue
		}
		url := a.BrowserDownloadURL
		if url == "" {
			url = shared.AgentGitHubBinaryURL(goarch)
		}
		stamp = a.Digest
		if stamp == "" {
			stamp = a.UpdatedAt
		}
		if stamp == "" {
			stamp = rel.PublishedAt
		}
		return stamp, url, nil
	}
	// Asset list missing — still allow direct download URL.
	return "", shared.AgentGitHubBinaryURL(goarch), nil
}

// remoteStamp returned a stamp for the current arch asset. Only the parked
// AutoUpdateLoop ever needed it; nothing decides anything from asset metadata
// now. Kept next to the loop it belongs to.
//
// func (u *Updater) remoteStamp() (string, error) {
// 	stamp, _, err := fetchGitHubAsset(runtime.GOARCH)
// 	if err != nil {
// 		return "", err
// 	}
// 	if stamp == "" {
// 		return "", fmt.Errorf("no stamp for %s", shared.AgentGitHubAssetName(runtime.GOARCH))
// 	}
// 	return stamp, nil
// }

// Update downloads the binary from the GitHub release and restarts. That is
// the whole contract: fetch what is on agentbeta right now, swap it in, come
// back up.
//
// Nothing is compared first. The release is a rolling tag overwritten in
// place, so its metadata cannot answer "did this change" honestly — a rebuild
// under the same tag keeps the digest and timestamp it had before. Every
// version of this that tried to be clever ended up refusing to download.
func (u *Updater) Update() (string, error) {
	// The asset URL is fixed and derivable, so the API call is only worth
	// making for the tidier download link; failing it changes nothing.
	_, url, err := fetchGitHubAsset(runtime.GOARCH)
	if err != nil || url == "" {
		url = shared.AgentGitHubBinaryURL(runtime.GOARCH)
	}
	bin, err := u.binPath()
	if err != nil {
		return "", err
	}

	client := &http.Client{Timeout: 3 * time.Minute}
	resp, err := client.Get(url)
	if err != nil {
		return "", fmt.Errorf("download: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("download failed: HTTP %d from %s", resp.StatusCode, url)
	}
	tmp := bin + ".new"
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o755)
	if err != nil {
		return "", err
	}
	n, err := io.Copy(f, resp.Body)
	f.Close()
	if err != nil {
		_ = os.Remove(tmp)
		return "", err
	}
	if n < 1024*1024 {
		_ = os.Remove(tmp)
		return "", fmt.Errorf("download too small (%d bytes) — check GitHub asset", n)
	}

	if err := copyFile(bin, u.prevPath(bin)); err != nil {
		return "", fmt.Errorf("backup current binary: %w", err)
	}
	if err := os.Rename(tmp, bin); err != nil {
		return "", fmt.Errorf("swap binary: %w", err)
	}
	u.restartSoon()
	// The size is worth reporting: against a rolling tag it is the only thing
	// distinguishing "a new build arrived" from "the same bytes came down
	// again", and the answer decides whether to go looking further.
	return fmt.Sprintf("downloaded %s from GitHub %s (%.1f MB), restarting",
		shared.AgentGitHubAssetName(runtime.GOARCH), shared.AgentReleaseTag,
		float64(n)/(1024*1024)), nil
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
	_ = os.Remove(u.stampPath(bin))
	u.restartSoon()
	return "rolled back to previous version, restarting", nil
}

func (u *Updater) restartSoon() {
	go func() {
		time.Sleep(500 * time.Millisecond)
		if runtime.GOOS == "linux" {
			if err := exec.Command("systemctl", "restart", "beacle-agent").Start(); err == nil {
				return
			}
		}
		os.Exit(0)
	}()
}

// AUTOMATIC UPDATES — parked until the update flow is designed properly.
//
// This ran unconditionally every six hours and was the reason the whole stamp
// mechanism existed: something had to stop the timer re-downloading the same
// asset forever. With the manual button now doing exactly what it says, none
// of that has a reason to exist yet, and an agent that replaces its own binary
// on a timer nobody asked for is a liability, not a feature.
//
// When this comes back it belongs behind the opt-in setting sketched in
// app/lib/update/app_updater.dart, off by default, and it will need its own
// way of deciding what "newer" means — the rolling agentbeta tag cannot answer
// that, which is what broke the button in the first place.
//
// func (u *Updater) AutoUpdateLoop() {
// 	for range time.Tick(6 * time.Hour) {
// 		bin, err := u.binPath()
// 		if err != nil {
// 			continue
// 		}
// 		stamp, err := u.remoteStamp()
// 		if err != nil || stamp == "" {
// 			continue
// 		}
// 		if prev, err := os.ReadFile(u.stampPath(bin)); err == nil && strings.TrimSpace(string(prev)) == stamp {
// 			continue
// 		}
// 		if _, err := u.Update(); err == nil {
// 			return
// 		}
// 	}
// }

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
