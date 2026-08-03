package main

import (
	"os"
	"strings"
	"testing"
)

func loadFixture(t *testing.T) []caddyBlock {
	t.Helper()
	b, err := os.ReadFile("testdata/Caddyfile")
	if err != nil {
		t.Fatalf("fixture: %v", err)
	}
	return parseCaddyfile(string(b))
}

func TestParsesEveryTopLevelBlock(t *testing.T) {
	blocks := loadFixture(t)
	if len(blocks) != 4 {
		for i, b := range blocks {
			t.Logf("block %d: %v", i, b.Addresses)
		}
		t.Fatalf("got %d blocks, want 4", len(blocks))
	}
}

func TestMultipleDomainsInOneBlock(t *testing.T) {
	b := loadFixture(t)[0]
	want := []string{"discordbothosting.pl", "www.discordbothosting.pl"}
	if len(b.Addresses) != len(want) {
		t.Fatalf("got %v, want %v", b.Addresses, want)
	}
	for i := range want {
		if b.Addresses[i] != want[i] {
			t.Errorf("address %d = %q, want %q", i, b.Addresses[i], want[i])
		}
	}
}

// Caddy accepts both separators on the address line. A space-separated block
// read as one hostname looks like a single-domain site, which would make the
// form offer to "edit" it and rewrite two domains into one.
func TestSpaceSeparatedAddresses(t *testing.T) {
	blocks := parseCaddyfile("a.com www.a.com {\n\treverse_proxy localhost:3000\n}\n")
	if len(blocks) != 1 {
		t.Fatalf("got %d blocks, want 1", len(blocks))
	}
	if got := blocks[0].Addresses; len(got) != 2 || got[0] != "a.com" || got[1] != "www.a.com" {
		t.Fatalf("addresses = %v, want [a.com www.a.com]", got)
	}
	if editableByForm(blocks[0]) {
		t.Error("a two-domain block must not be editable by the single-domain form")
	}
}

func TestNestedBlocksDoNotEndTheSite(t *testing.T) {
	// dash.* contains header{}, a matcher and two handle{} blocks. Naive brace
	// counting would close the site at the first '}' and lose the rest.
	blocks := loadFixture(t)
	var dash *caddyBlock
	for i := range blocks {
		if blocks[i].Addresses[0] == "dash.discordbothosting.pl" {
			dash = &blocks[i]
		}
	}
	if dash == nil {
		t.Fatal("dash.discordbothosting.pl block not found")
	}
	for _, want := range []string{"@api", "handle @api", "reverse_proxy localhost:18080", "file_server"} {
		if !strings.Contains(dash.Body, want) {
			t.Errorf("body lost %q:\n%s", want, dash.Body)
		}
	}
}

func TestClassification(t *testing.T) {
	blocks := loadFixture(t)
	want := map[string]string{
		"discordbothosting.pl":      siteKindStatic, // root + file_server
		"dash.discordbothosting.pl": siteKindMixed,  // SPA plus an /api proxy
		"http://ai.niedojeby.lol":   siteKindProxy,
		"http://fivem.niedojeby.lol": siteKindProxy,
	}
	for _, b := range blocks {
		got := classifyBlock(b.Body)
		if w, ok := want[b.Addresses[0]]; ok && got != w {
			t.Errorf("%s classified as %s, want %s", b.Addresses[0], got, w)
		}
	}
}

func TestUpstreamExtraction(t *testing.T) {
	blocks := loadFixture(t)
	want := map[string]string{
		"http://ai.niedojeby.lol":    "localhost:8080",
		"http://fivem.niedojeby.lol": "localhost:30120",
		"dash.discordbothosting.pl":  "localhost:18080", // nested inside handle @api
	}
	for _, b := range blocks {
		if w, ok := want[b.Addresses[0]]; ok {
			if got := directiveArg(b.Body, "reverse_proxy"); got != w {
				t.Errorf("%s upstream = %q, want %q", b.Addresses[0], got, w)
			}
		}
	}
}

func TestOnlySimpleProxyBlocksAreEditable(t *testing.T) {
	blocks := loadFixture(t)
	want := map[string]bool{
		// Static site with try_files — regenerating it would turn a working
		// SPA into a bare reverse proxy.
		"discordbothosting.pl": false,
		// Matchers and handle blocks cannot be expressed by the form.
		"dash.discordbothosting.pl": false,
		// Plain one-line proxies are safe to edit.
		"http://ai.niedojeby.lol":    true,
		"http://fivem.niedojeby.lol": true,
	}
	for _, b := range blocks {
		if w, ok := want[b.Addresses[0]]; ok {
			if got := editableByForm(b); got != w {
				t.Errorf("%s editable = %v, want %v", b.Addresses[0], got, w)
			}
		}
	}
}

func TestTLSMode(t *testing.T) {
	blocks := loadFixture(t)
	want := map[string]string{
		"discordbothosting.pl":       "internal", // behind Cloudflare
		"dash.discordbothosting.pl":  "internal",
		"http://ai.niedojeby.lol":    "none",
		"http://fivem.niedojeby.lol": "none",
	}
	for _, b := range blocks {
		if w, ok := want[b.Addresses[0]]; ok {
			if got := tlsMode(b); got != w {
				t.Errorf("%s tls = %q, want %q", b.Addresses[0], got, w)
			}
		}
	}
}

func TestRawBlockIsPreservedVerbatim(t *testing.T) {
	// The raw text is what the panel shows and what protects config it cannot
	// model, so it has to come back byte for byte.
	blocks := loadFixture(t)
	for _, b := range blocks {
		if b.Addresses[0] != "dash.discordbothosting.pl" {
			continue
		}
		for _, want := range []string{
			`header {`,
			`Cache-Control "no-cache, no-store, must-revalidate"`,
			`@api path /auth/* /public/* /health /me /bot/* /admin/*`,
			`try_files {path} {path}/ /index.html`,
		} {
			if !strings.Contains(b.Raw, want) {
				t.Errorf("raw block lost %q", want)
			}
		}
	}
}

func TestCommentsAndPlaceholdersDoNotBreakParsing(t *testing.T) {
	src := `# a comment with { an unbalanced brace
example.com {
	respond "hello # not a comment"
	try_files {path} {path}/ /index.html
}
`
	blocks := parseCaddyfile(src)
	if len(blocks) != 1 {
		t.Fatalf("got %d blocks, want 1", len(blocks))
	}
	if blocks[0].Addresses[0] != "example.com" {
		t.Errorf("address = %v", blocks[0].Addresses)
	}
	if !strings.Contains(blocks[0].Body, "try_files") {
		t.Error("placeholders {path} must not be treated as block braces")
	}
}

func TestStripComments(t *testing.T) {
	cases := map[string]string{
		`root * /srv # trailing`:      `root * /srv `,
		`respond "a # b"`:             `respond "a # b"`,
		`# whole line`:                ``,
		`header X "v" # note`:         `header X "v" `,
	}
	for in, want := range cases {
		if got := stripComments(in); got != want {
			t.Errorf("stripComments(%q) = %q, want %q", in, got, want)
		}
	}
}
