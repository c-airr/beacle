package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"sync"
	"time"

	"beacle/shared"
)

// handleDownloadAgent redirects to the public GitHub agentbeta asset.
func (s *Server) handleDownloadAgent(w http.ResponseWriter, r *http.Request) {
	arch := r.URL.Query().Get("arch")
	if arch == "" {
		arch = "amd64"
	}
	url := shared.AgentGitHubBinaryURL(arch)
	w.Header().Set("X-Beacle-Agent-Source", url)
	http.Redirect(w, r, url, http.StatusFound)
}

func (s *Server) handleAgentVersion(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{
		"version": githubAgentStamp("amd64"),
		"source":  shared.AgentGitHubBinaryURL("amd64"),
		"tag":     shared.AgentReleaseTag,
	})
}

var (
	ghStampMu   sync.Mutex
	ghStampCache = map[string]struct {
		stamp string
		at    time.Time
	}{}
)

func githubAgentStamp(goarch string) string {
	ghStampMu.Lock()
	if c, ok := ghStampCache[goarch]; ok && time.Since(c.at) < 2*time.Minute {
		ghStampMu.Unlock()
		return c.stamp
	}
	ghStampMu.Unlock()

	stamp := fetchGitHubStamp(goarch)
	if stamp == "" {
		stamp = shared.AgentReleaseTag
	}
	ghStampMu.Lock()
	ghStampCache[goarch] = struct {
		stamp string
		at    time.Time
	}{stamp: stamp, at: time.Now()}
	ghStampMu.Unlock()
	return stamp
}

func fetchGitHubStamp(goarch string) string {
	req, err := http.NewRequest(http.MethodGet, shared.AgentGitHubReleaseAPI(), nil)
	if err != nil {
		return ""
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", "beacle-backend")

	client := &http.Client{Timeout: 12 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		log.Printf("github release meta: %v", err)
		return ""
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		log.Printf("github release meta HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(b)))
		return ""
	}
	var rel struct {
		PublishedAt string `json:"published_at"`
		Assets      []struct {
			Name      string `json:"name"`
			UpdatedAt string `json:"updated_at"`
			Digest    string `json:"digest"`
		} `json:"assets"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&rel); err != nil {
		return ""
	}
	want := shared.AgentGitHubAssetName(goarch)
	for _, a := range rel.Assets {
		if a.Name != want {
			continue
		}
		if a.Digest != "" {
			return a.Digest
		}
		if a.UpdatedAt != "" {
			return a.UpdatedAt
		}
	}
	return rel.PublishedAt
}

// unused import guard if fmt only used elsewhere — keep fmt for errors in install
var _ = fmt.Sprintf
