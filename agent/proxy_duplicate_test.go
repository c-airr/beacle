package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"beacle/shared"
)

// Caddy refuses to start when two blocks claim the same site address, and that
// failure takes down every other site on the machine. These two paths are the
// only ways the panel could create that clash.

func TestAddSiteRejectsDomainAlreadyInCaddyfile(t *testing.T) {
	src, err := os.ReadFile("testdata/Caddyfile")
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	path := filepath.Join(dir, "Caddyfile")
	if err := os.WriteFile(path, src, 0o644); err != nil {
		t.Fatal(err)
	}
	a := &caddyAdapter{dir: filepath.Join(dir, "beacle.d"), caddyfile: path}

	for _, domain := range []string{
		"ai.niedojeby.lol",       // declared as http://ai.niedojeby.lol
		"dash.discordbothosting.pl",
		"AI.NIEDOJEBY.LOL", // case must not be a way around it
	} {
		_, err := a.AddSite(shared.ProxySiteRequest{Domain: domain, Upstream: "3000"})
		if err == nil {
			t.Errorf("%s: adding a duplicate site was allowed", domain)
			continue
		}
		if !strings.Contains(err.Error(), "already defined") {
			t.Errorf("%s: unhelpful error %q", domain, err)
		}
	}

	// A fresh domain still works.
	if _, err := a.AddSite(shared.ProxySiteRequest{Domain: "new.example.com", Upstream: "3000"}); err != nil {
		t.Errorf("adding an unused domain failed: %v", err)
	}
}

func TestUpdateSiteRefusesCaddyfileBackedIDs(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "Caddyfile")
	if err := os.WriteFile(path, []byte("http://ai.niedojeby.lol {\n\treverse_proxy localhost:8080\n}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	a := &caddyAdapter{dir: filepath.Join(dir, "beacle.d"), caddyfile: path}

	_, err := a.UpdateSite("caddyfile:ai.niedojeby.lol", shared.ProxySiteRequest{
		Domain: "ai.niedojeby.lol", Upstream: "9999",
	})
	if err == nil {
		t.Fatal("editing a Caddyfile-backed site was allowed — it would duplicate the site address")
	}
	if !strings.Contains(err.Error(), "defined in") {
		t.Errorf("unhelpful error: %v", err)
	}
}
