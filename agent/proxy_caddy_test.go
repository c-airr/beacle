package main

import (
	"encoding/json"
	"strings"
	"testing"

	"beacle/shared"
)

func jsonUnmarshalString(s string, v any) error { return json.Unmarshal([]byte(s), v) }

func TestNormalizeUpstream(t *testing.T) {
	cases := map[string]string{
		"3000":                   "127.0.0.1:3000", // bare port is what people type
		"localhost:3000":         "localhost:3000",
		"127.0.0.1:8080":         "127.0.0.1:8080",
		"http://127.0.0.1:8080":  "http://127.0.0.1:8080",
		"https://backend:8443":   "https://backend:8443",
		"unix//run/app.sock":     "unix//run/app.sock",
	}
	for in, want := range cases {
		if got := normalizeUpstream(in); got != want {
			t.Errorf("normalizeUpstream(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestUpstreamPort(t *testing.T) {
	cases := map[string]int{
		"127.0.0.1:3000":        3000,
		"http://127.0.0.1:8080": 8080,
		"localhost:65535":       65535,
		"localhost":             0,
		"127.0.0.1:0":           0,
		"127.0.0.1:99999":       0,
		"http://host/path":      0,
	}
	for in, want := range cases {
		if got := upstreamPort(in); got != want {
			t.Errorf("upstreamPort(%q) = %d, want %d", in, got, want)
		}
	}
}

func TestValidateSiteRequestRejectsConfigInjection(t *testing.T) {
	// These do not "break the site" — they rewrite the server's routing.
	bad := []shared.ProxySiteRequest{
		{Domain: "", Upstream: "3000"},
		{Domain: "ok.com", Upstream: ""},
		{Domain: "ok.com\n}\nevil.com {\n\treverse_proxy 1.2.3.4:80", Upstream: "3000"},
		{Domain: "ok.com {", Upstream: "3000"},
		{Domain: "ok com", Upstream: "3000"},
		{Domain: "ok.com", Upstream: "3000\n}\nevil.com {"},
		{Domain: "ok.com", Upstream: "127.0.0.1:3000 # comment"},
		{Domain: "ok.com", Upstream: "3000", BasicAuthUser: "admin"},                        // hash missing
		{Domain: "ok.com", Upstream: "3000", BasicAuthHash: "$2a$..."},                      // user missing
		{Domain: "ok.com", Upstream: "3000", BasicAuthUser: "a b", BasicAuthHash: "$2a$x"},  // space
		{Domain: "ok.com", Upstream: "3000", Headers: map[string]string{"X\nY": "1"}},
		{Domain: "ok.com", Upstream: "3000", Headers: map[string]string{"X": "a\nb"}},
	}
	for i, req := range bad {
		if err := validateSiteRequest(req); err == nil {
			t.Errorf("case %d: accepted a request it should reject: %+v", i, req)
		}
	}

	good := []shared.ProxySiteRequest{
		{Domain: "example.com", Upstream: "3000"},
		{Domain: "*.example.com", Upstream: "localhost:8080"},
		{Domain: "sub.example.com", Upstream: "http://127.0.0.1:9000", EnableSSL: true},
		{Domain: "ok.com", Upstream: "3000", BasicAuthUser: "admin", BasicAuthHash: "$2a$14$abc"},
		{Domain: "ok.com", Upstream: "3000", Headers: map[string]string{"Strict-Transport-Security": "max-age=31536000"}},
	}
	for i, req := range good {
		if err := validateSiteRequest(req); err != nil {
			t.Errorf("case %d: rejected a valid request: %v", i, err)
		}
	}
}

func TestRenderCaddySiteBasics(t *testing.T) {
	out := renderCaddySite(caddySiteMeta{
		ID: "abc", Domain: "example.com", Upstream: "3000", EnableSSL: true,
	})

	if !strings.Contains(out, "# beacle:") {
		t.Error("metadata comment missing — the panel could not read the site back")
	}
	if !strings.Contains(out, "example.com {") {
		t.Errorf("site block missing:\n%s", out)
	}
	if !strings.Contains(out, "reverse_proxy 127.0.0.1:3000") {
		t.Errorf("bare port was not normalized:\n%s", out)
	}
	if strings.Contains(out, "http://example.com") {
		t.Errorf("SSL site must not be pinned to http://:\n%s", out)
	}
}

func TestRenderCaddySiteWithoutSSLUsesHTTP(t *testing.T) {
	out := renderCaddySite(caddySiteMeta{ID: "a", Domain: "example.com", Upstream: "3000"})
	if !strings.Contains(out, "http://example.com {") {
		t.Errorf("non-SSL site should be explicit about http://:\n%s", out)
	}
}

func TestRenderCaddySiteOptions(t *testing.T) {
	out := renderCaddySite(caddySiteMeta{
		ID: "a", Domain: "example.com", Upstream: "3000", EnableSSL: true,
		RedirectWWW: true, WebSocket: true, GzipEncoding: true, AccessLog: true,
		BasicAuthUser: "admin", BasicAuthHash: "$2a$14$abc",
		Headers: map[string]string{"Strict-Transport-Security": "max-age=31536000"},
	})

	for _, want := range []string{
		"www.example.com {",                 // redirect block
		"redir https://example.com{uri}",    // redirect target
		"encode gzip zstd",                  // compression
		"basic_auth {",                      // auth
		"admin $2a$14$abc",                  // credentials
		"Strict-Transport-Security",         // custom header
		"output file /var/log/caddy/example.com.log", // per-site log
		"header_up Host {upstream_hostport}",         // websocket
	} {
		if !strings.Contains(out, want) {
			t.Errorf("expected %q in rendered config:\n%s", want, out)
		}
	}
}

func TestRenderCaddySiteRoundTripsThroughMeta(t *testing.T) {
	// The first-line JSON is the source of truth the panel edits, so every
	// option has to survive a render → parse cycle.
	in := caddySiteMeta{
		ID: "id1", Domain: "example.com", Upstream: "127.0.0.1:3000", EnableSSL: true,
		RedirectWWW: true, WebSocket: true, GzipEncoding: true, AccessLog: true,
		BasicAuthUser: "admin", BasicAuthHash: "$2a$14$abc",
		Headers: map[string]string{"X-Frame-Options": "DENY"},
	}
	rendered := renderCaddySite(in)

	first, _, _ := strings.Cut(rendered, "\n")
	if !strings.HasPrefix(first, "# beacle:") {
		t.Fatalf("no metadata line: %q", first)
	}
	var got caddySiteMeta
	if err := jsonUnmarshalString(strings.TrimPrefix(first, "# beacle:"), &got); err != nil {
		t.Fatalf("metadata does not parse: %v", err)
	}

	if got.Domain != in.Domain || got.Upstream != in.Upstream || !got.EnableSSL {
		t.Errorf("core fields lost: %+v", got)
	}
	if !got.RedirectWWW || !got.WebSocket || !got.GzipEncoding || !got.AccessLog {
		t.Errorf("toggles lost in round trip: %+v", got)
	}
	if got.BasicAuthUser != "admin" || got.Headers["X-Frame-Options"] != "DENY" {
		t.Errorf("auth/headers lost in round trip: %+v", got)
	}
}
