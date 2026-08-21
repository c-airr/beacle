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
// ?tag= pins a specific release for the version picker in Settings.
func (s *Server) handleDownloadAgent(w http.ResponseWriter, r *http.Request) {
	arch := r.URL.Query().Get("arch")
	if arch == "" {
		arch = "amd64"
	}
	url := shared.AgentGitHubBinaryURL(arch)
	if tag := r.URL.Query().Get("tag"); tag != "" {
		url = shared.AgentGitHubBinaryURLTag(tag, arch)
	}
	w.Header().Set("X-Beacle-Agent-Source", url)
	http.Redirect(w, r, url, http.StatusFound)
}

// handleAgentVersion describes the agent build on GitHub's Latest release.
//
// "version" is the asset's sha256 digest rather than a release name, because
// what an agent needs to know is whether the bytes on GitHub differ from the
// bytes it is running. A rebuilt binary published under the same version number
// has the same name and a different digest, and it is the digest that decides
// whether an update is worth doing.
func (s *Server) handleAgentVersion(w http.ResponseWriter, r *http.Request) {
	rel := githubAgentRelease("amd64")
	writeJSON(w, http.StatusOK, map[string]string{
		"version": rel.stamp,
		"source":  shared.AgentGitHubBinaryURL("amd64"),
		"tag":     rel.tag,
	})
}

// agentRelease is what the panel knows about the agent build on Latest.
type agentRelease struct {
	tag   string // release name, for display
	stamp string // asset digest, for deciding whether to update
	at    time.Time
}

var (
	ghStampMu    sync.Mutex
	ghStampCache = map[string]agentRelease{}
)

// githubAgentRelease is cached briefly: every agent asks on every version
// check, and GitHub rate-limits unauthenticated callers.
func githubAgentRelease(goarch string) agentRelease {
	ghStampMu.Lock()
	if c, ok := ghStampCache[goarch]; ok && time.Since(c.at) < 2*time.Minute {
		ghStampMu.Unlock()
		return c
	}
	ghStampMu.Unlock()

	rel := fetchGitHubRelease(goarch)
	rel.at = time.Now()
	// An empty stamp means GitHub could not be reached. Cached anyway, so a
	// rate-limited backend does not hammer the API once per agent per check;
	// the agent treats an empty stamp as "cannot tell" and does not update.
	ghStampMu.Lock()
	ghStampCache[goarch] = rel
	ghStampMu.Unlock()
	return rel
}

func githubAgentStamp(goarch string) string { return githubAgentRelease(goarch).stamp }

func fetchGitHubRelease(goarch string) agentRelease {
	req, err := http.NewRequest(http.MethodGet, shared.AgentGitHubReleaseAPI(), nil)
	if err != nil {
		return agentRelease{}
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", "beacle-backend")

	client := &http.Client{Timeout: 12 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		log.Printf("github release meta: %v", err)
		return agentRelease{}
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		log.Printf("github release meta HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(b)))
		return agentRelease{}
	}
	var rel struct {
		TagName     string `json:"tag_name"`
		PublishedAt string `json:"published_at"`
		Assets      []struct {
			Name      string `json:"name"`
			UpdatedAt string `json:"updated_at"`
			Digest    string `json:"digest"`
		} `json:"assets"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&rel); err != nil {
		return agentRelease{}
	}

	out := agentRelease{tag: rel.TagName}
	want := shared.AgentGitHubAssetName(goarch)
	for _, a := range rel.Assets {
		if a.Name != want {
			continue
		}
		// Digest first: it changes whenever the bytes change, which is the
		// only question being asked. The timestamps are fallbacks for older
		// releases uploaded before GitHub exposed digests.
		switch {
		case a.Digest != "":
			out.stamp = a.Digest
		case a.UpdatedAt != "":
			out.stamp = a.UpdatedAt
		default:
			out.stamp = rel.PublishedAt
		}
		return out
	}
	// The release exists but carries no agent for this architecture. Leaving
	// the stamp empty is deliberate: "no build for you" must not read as "you
	// are up to date".
	return out
}

// unused import guard if fmt only used elsewhere — keep fmt for errors in install
var _ = fmt.Sprintf
