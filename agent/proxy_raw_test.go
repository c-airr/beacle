package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The whole point of raw editing is that it touches one block. Everything
// around it — comments, formatting, other sites — has to come back untouched,
// because that config is the user's, not Beacle's.
func TestReplaceBlockLeavesTheRestOfTheFileAlone(t *testing.T) {
	src, err := os.ReadFile("testdata/Caddyfile")
	if err != nil {
		t.Fatalf("fixture: %v", err)
	}
	blocks := parseCaddyfile(string(src))

	var target caddyBlock
	for _, b := range blocks {
		if b.Addresses[0] == "http://ai.niedojeby.lol" {
			target = b
		}
	}
	if target.Addresses == nil {
		t.Fatal("fixture block not found")
	}

	out, err := replaceBlock(string(src), target, "ai.niedojeby.lol {\n\ttls internal\n\treverse_proxy localhost:9999\n}")
	if err != nil {
		t.Fatalf("replaceBlock: %v", err)
	}

	if strings.Contains(out, "localhost:8080") {
		t.Error("old upstream survived the replacement")
	}
	if !strings.Contains(out, "reverse_proxy localhost:9999") {
		t.Error("new block is not in the output")
	}
	// Neighbours and comments must be byte-identical.
	for _, want := range []string{
		"# Caddy — produkcja (kopiuj do /etc/caddy/Caddyfile i: systemctl reload caddy)",
		"discordbothosting.pl, www.discordbothosting.pl {",
		"@api path /auth/* /public/* /health /me /bot/* /admin/*",
		"http://fivem.niedojeby.lol {",
		"reverse_proxy localhost:30120",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("replacement damaged the rest of the file, lost: %q", want)
		}
	}
	// And the file still has exactly as many blocks as before.
	if got := len(parseCaddyfile(out)); got != len(blocks) {
		t.Errorf("block count changed: %d -> %d", len(blocks), got)
	}
}

// A block in the middle of the file must not shift its neighbours by a line.
func TestReplaceBlockWithDifferentLineCount(t *testing.T) {
	src := "a.com {\n\treverse_proxy :1\n}\n\nb.com {\n\treverse_proxy :2\n}\n\nc.com {\n\treverse_proxy :3\n}\n"
	blocks := parseCaddyfile(src)
	if len(blocks) != 3 {
		t.Fatalf("got %d blocks", len(blocks))
	}

	out, err := replaceBlock(src, blocks[1], "b.com {\n\thandle /api/* {\n\t\treverse_proxy :2\n\t}\n\tfile_server\n}")
	if err != nil {
		t.Fatal(err)
	}
	after := parseCaddyfile(out)
	if len(after) != 3 {
		t.Fatalf("block count changed: %v", len(after))
	}
	for i, want := range []string{"a.com", "b.com", "c.com"} {
		if after[i].Addresses[0] != want {
			t.Errorf("block %d = %s, want %s", i, after[i].Addresses[0], want)
		}
	}
	if !strings.Contains(after[1].Body, "handle /api/*") {
		t.Error("replacement body missing")
	}
	if !strings.Contains(after[2].Body, "reverse_proxy :3") {
		t.Error("the block after the edit was damaged")
	}
}

func TestUpdateSiteRawRejectsGarbage(t *testing.T) {
	a := &caddyAdapter{dir: t.TempDir(), caddyfile: filepath.Join(t.TempDir(), "Caddyfile")}
	for _, raw := range []string{
		"",
		"   \n  ",
		"example.com {\n\treverse_proxy :3000", // missing closing brace
		"just some words",
	} {
		if _, err := a.UpdateSiteRaw("caddyfile:example.com", raw); err == nil {
			t.Errorf("accepted invalid raw config: %q", raw)
		}
	}
}

// A hand-edited managed file must round trip: what the panel shows next time
// has to be exactly what the user saved, with no banner pile-up.
func TestManagedRawFileRoundTrip(t *testing.T) {
	m := caddySiteMeta{ID: "abc", Domain: "example.com", Upstream: "127.0.0.1:3000", RawEdit: true}
	raw := "example.com {\n\thandle /api/* {\n\t\treverse_proxy 127.0.0.1:3000\n\t}\n\tfile_server\n}"

	content := renderRawSite(m, raw)
	got, block, ok := splitManagedFile(content)
	if !ok {
		t.Fatal("file written by renderRawSite does not parse back")
	}
	if !got.RawEdit {
		t.Error("raw_edit flag lost")
	}
	if block != raw {
		t.Errorf("block changed in round trip:\n got: %q\nwant: %q", block, raw)
	}

	// Saving the same block again must not stack another banner on top.
	again, block2, _ := splitManagedFile(renderRawSite(got, block))
	if block2 != raw {
		t.Errorf("second round trip drifted: %q", block2)
	}
	if !again.RawEdit {
		t.Error("raw_edit flag lost on second save")
	}
}

// Beacle's own banner is stripped on read, but a comment the user wrote is
// theirs and has to survive.
func TestUserCommentSurvivesRoundTrip(t *testing.T) {
	m := caddySiteMeta{ID: "abc", Domain: "example.com"}
	raw := "# my own note about this site\nexample.com {\n\treverse_proxy :3000\n}"
	_, block, ok := splitManagedFile(renderRawSite(m, raw))
	if !ok {
		t.Fatal("does not parse back")
	}
	if block != raw {
		t.Errorf("user comment did not survive:\n got: %q\nwant: %q", block, raw)
	}
}

// Generated sites keep working exactly as before: no raw flag, and the block
// is still regenerated from the metadata.
func TestGeneratedSiteStillParsesAfterBannerRefactor(t *testing.T) {
	m := caddySiteMeta{ID: "abc", Domain: "example.com", Upstream: "3000", EnableSSL: true}
	got, block, ok := splitManagedFile(renderCaddySite(m))
	if !ok {
		t.Fatal("generated site file does not parse back")
	}
	if got.RawEdit {
		t.Error("generated site must not be marked raw-edited")
	}
	if !strings.HasPrefix(block, "example.com {") {
		t.Errorf("banner not stripped from generated file: %q", block)
	}
}
