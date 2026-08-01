package main

import (
	"os"
	"path/filepath"
	"testing"

	"beacle/shared"
)

// Exercises the whole path: real Caddyfile on disk → the site list the panel
// renders. The guarantee that matters is that a hand-written production block
// is visible but never marked editable.
func TestLoadCaddyfileSitesFromRealConfig(t *testing.T) {
	src, err := os.ReadFile("testdata/Caddyfile")
	if err != nil {
		t.Fatalf("fixture: %v", err)
	}
	dir := t.TempDir()
	path := filepath.Join(dir, "Caddyfile")
	if err := os.WriteFile(path, src, 0o644); err != nil {
		t.Fatal(err)
	}

	a := &caddyAdapter{dir: filepath.Join(dir, "beacle.d"), caddyfile: path}
	sites := a.loadCaddyfileSites(nil)

	if len(sites) != 4 {
		for _, s := range sites {
			t.Logf("site: %s", s.Domain)
		}
		t.Fatalf("got %d sites, want 4", len(sites))
	}

	byDomain := map[string]shared.ProxySite{}
	for _, s := range sites {
		byDomain[s.Domain] = s
	}

	for _, d := range []string{
		"discordbothosting.pl", "dash.discordbothosting.pl",
		"ai.niedojeby.lol", "fivem.niedojeby.lol",
	} {
		if _, ok := byDomain[d]; !ok {
			t.Errorf("missing site %s", d)
		}
	}

	// The http:// prefix is a Caddy scheme, not part of the hostname.
	if s := byDomain["ai.niedojeby.lol"]; s.Upstream != "localhost:8080" {
		t.Errorf("ai upstream = %q", s.Upstream)
	}

	// Everything from the main file is unmanaged.
	for _, s := range sites {
		if s.Managed {
			t.Errorf("%s must not be reported as Beacle-managed", s.Domain)
		}
		if s.SourceFile != path {
			t.Errorf("%s source = %q, want %q", s.Domain, s.SourceFile, path)
		}
		if s.RawConfig == "" {
			t.Errorf("%s has no raw config to display", s.Domain)
		}
	}

	// The dangerous ones must be read-only, with a reason to show the user.
	for _, d := range []string{"discordbothosting.pl", "dash.discordbothosting.pl"} {
		s := byDomain[d]
		if s.Editable {
			t.Errorf("%s must not be editable — saving would destroy a working site", d)
		}
		if s.ReadOnlyReason == "" {
			t.Errorf("%s is read-only but gives no reason", d)
		}
	}

	// Plain proxies are safe to edit.
	for _, d := range []string{"ai.niedojeby.lol", "fivem.niedojeby.lol"} {
		if !byDomain[d].Editable {
			t.Errorf("%s is a plain reverse proxy and should be editable", d)
		}
	}

	// Multi-domain block keeps both names for display.
	if got := byDomain["discordbothosting.pl"].Domains; len(got) != 2 {
		t.Errorf("discordbothosting.pl domains = %v, want 2 entries", got)
	}

	// tls internal must be visible: behind Cloudflare it otherwise looks broken.
	if got := byDomain["discordbothosting.pl"].TLSMode; got != "internal" {
		t.Errorf("tls mode = %q, want internal", got)
	}
}

func TestBeacleManagedSitesWinOverCaddyfile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "Caddyfile")
	if err := os.WriteFile(path, []byte("http://ai.niedojeby.lol {\n\treverse_proxy localhost:8080\n}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	a := &caddyAdapter{dir: filepath.Join(dir, "beacle.d"), caddyfile: path}

	// Same domain already managed by Beacle — it must not appear twice.
	managed := []shared.ProxySite{{Domain: "ai.niedojeby.lol", Managed: true}}
	if got := a.loadCaddyfileSites(managed); len(got) != 0 {
		t.Errorf("duplicate site returned: %+v", got)
	}
}

func TestMissingCaddyfileIsNotAnError(t *testing.T) {
	a := &caddyAdapter{dir: t.TempDir(), caddyfile: filepath.Join(t.TempDir(), "nope")}
	if got := a.loadCaddyfileSites(nil); got != nil {
		t.Errorf("expected no sites, got %+v", got)
	}
}
