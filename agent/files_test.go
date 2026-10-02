package main

import (
	"encoding/base64"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"testing"

	"beacle/shared"
)

func newFiles(t *testing.T, files map[string]string) *FileManager {
	t.Helper()
	root := t.TempDir()
	for rel, content := range files {
		p := filepath.Join(root, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return &FileManager{root: root}
}

func wantStatus(t *testing.T, err error, code int) {
	t.Helper()
	if err == nil {
		t.Fatalf("want HTTP %d, got no error", code)
	}
	if got := fsStatus(err); got != code {
		t.Fatalf("want HTTP %d, got %d (%v)", code, got, err)
	}
}

func TestListingPutsDirectoriesFirstAndHidesDotfilesByDefault(t *testing.T) {
	m := newFiles(t, map[string]string{
		"srv/b.txt":     "b",
		"srv/A.txt":     "a",
		"srv/.env":      "secret",
		"srv/zdir/x":    "x",
		"srv/adir/keep": "",
	})
	l, err := m.List("/srv", false)
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, e := range l.Entries {
		names = append(names, e.Name)
	}
	want := []string{"adir", "zdir", "A.txt", "b.txt"}
	if len(names) != len(want) {
		t.Fatalf("got %v, want %v", names, want)
	}
	for i := range want {
		if names[i] != want[i] {
			t.Fatalf("got %v, want %v", names, want)
		}
	}
	if l.Parent != "/" || l.Entries[2].Path != "/srv/A.txt" || l.Entries[2].Version == "" {
		t.Fatalf("paths are wire paths, files carry a version: %+v", l)
	}

	l, _ = m.List("/srv", true)
	if len(l.Entries) != 5 {
		t.Fatalf("hidden=1 should include .env, got %d entries", len(l.Entries))
	}
}

func TestRelativePathsAreRejected(t *testing.T) {
	m := newFiles(t, nil)
	_, err := m.List("etc", false)
	wantStatus(t, err, http.StatusBadRequest)
}

func TestReadReturnsChunksAndFlagsBinaries(t *testing.T) {
	m := newFiles(t, map[string]string{
		"a.txt":   "hello world",
		"img.bin": "PNG\x00\x01\x02",
	})
	r, err := m.Read("/a.txt", 6, 3)
	if err != nil {
		t.Fatal(err)
	}
	got, _ := base64.StdEncoding.DecodeString(r.Data)
	if string(got) != "wor" || r.EOF || r.Size != 11 {
		t.Fatalf("chunk = %q eof=%v size=%d", got, r.EOF, r.Size)
	}
	if r, _ = m.Read("/a.txt", 0, 0); r.Binary || !r.EOF {
		t.Fatalf("text file read whole: binary=%v eof=%v", r.Binary, r.EOF)
	}
	if r, _ = m.Read("/img.bin", 0, 0); !r.Binary {
		t.Fatal("NUL bytes should mark the file binary")
	}
	_, err = m.Read("/", 0, 0)
	wantStatus(t, err, http.StatusBadRequest)
	_, err = m.Read("/missing", 0, 0)
	wantStatus(t, err, http.StatusNotFound)
}

func TestSaveRefusesAFileChangedOnTheServer(t *testing.T) {
	m := newFiles(t, map[string]string{"app/.env": "A=1\n"})
	r, _ := m.Read("/app/.env", 0, 0)

	if _, err := m.Write(shared.FSWriteRequest{Path: "/app/.env", Content: "A=2\n", Version: r.Version}); err != nil {
		t.Fatal(err)
	}
	// Second save with the version from before the first one is stale.
	_, err := m.Write(shared.FSWriteRequest{Path: "/app/.env", Content: "A=3\n", Version: r.Version})
	wantStatus(t, err, http.StatusConflict)

	b, _ := os.ReadFile(m.local("/app/.env"))
	if string(b) != "A=2\n" {
		t.Fatalf("stale save must not land, file is %q", b)
	}
}

func TestCreatingAFileThatExistsIsAConflict(t *testing.T) {
	m := newFiles(t, map[string]string{"x": "old"})
	_, err := m.Write(shared.FSWriteRequest{Path: "/x", Content: "new"})
	wantStatus(t, err, http.StatusConflict)

	e, err := m.Write(shared.FSWriteRequest{Path: "/y", Content: "new"})
	if err != nil || e.Size != 3 {
		t.Fatalf("create new file: %+v %v", e, err)
	}
}

func TestUploadAssemblesChunksAndOnlyLandsOnFinal(t *testing.T) {
	m := newFiles(t, map[string]string{"dst/.keep": ""})
	chunk := func(s string) string { return base64.StdEncoding.EncodeToString([]byte(s)) }

	if _, err := m.Upload(shared.FSUploadRequest{Path: "/dst/db.sqlite", Data: chunk("abc")}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(m.local("/dst/db.sqlite")); err == nil {
		t.Fatal("file must not appear under its real name before Final")
	}

	// A retried first chunk arrives again: the offset tells the panel to resume.
	res, err := m.Upload(shared.FSUploadRequest{Path: "/dst/db.sqlite", Offset: 1, Data: chunk("x")})
	wantStatus(t, err, http.StatusConflict)
	if res.Received != 3 {
		t.Fatalf("resume point = %d, want 3", res.Received)
	}

	res, err = m.Upload(shared.FSUploadRequest{Path: "/dst/db.sqlite", Offset: 3, Data: chunk("def"), Final: true})
	if err != nil || res.Entry == nil || res.Entry.Size != 6 {
		t.Fatalf("final chunk: %+v %v", res, err)
	}
	b, _ := os.ReadFile(m.local("/dst/db.sqlite"))
	if string(b) != "abcdef" {
		t.Fatalf("assembled %q", b)
	}

	_, err = m.Upload(shared.FSUploadRequest{Path: "/dst/db.sqlite", Data: chunk("zz"), Final: true})
	wantStatus(t, err, http.StatusConflict)
	if _, err := m.Upload(shared.FSUploadRequest{Path: "/dst/db.sqlite", Data: chunk("zz"), Final: true, Overwrite: true}); err != nil {
		t.Fatalf("overwrite: %v", err)
	}
}

func TestDeleteGuardsTheSystemAndNonEmptyDirectories(t *testing.T) {
	m := newFiles(t, map[string]string{
		"etc/hosts":                    "",
		"opt/beacle-agent/config.json": "{}",
		"srv/site/index.html":          "",
	})
	for _, p := range []string{"/", "/etc", "/opt/beacle-agent/config.json"} {
		wantStatus(t, m.Delete(shared.FSPathRequest{Path: p, Recursive: true}), http.StatusForbidden)
	}
	wantStatus(t, m.Delete(shared.FSPathRequest{Path: "/srv/site"}), http.StatusConflict)
	if err := m.Delete(shared.FSPathRequest{Path: "/srv/site", Recursive: true}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(m.local("/srv/site")); err == nil {
		t.Fatal("recursive delete left the directory")
	}
}

func TestRenameRefusesClobberAndSelfNesting(t *testing.T) {
	m := newFiles(t, map[string]string{"srv/a/f": "1", "srv/b": "2"})
	_, err := m.Rename(shared.FSRenameRequest{From: "/srv/a", To: "/srv/b"})
	wantStatus(t, err, http.StatusConflict)
	_, err = m.Rename(shared.FSRenameRequest{From: "/srv/a", To: "/srv/a/inner"})
	wantStatus(t, err, http.StatusBadRequest)
	_, err = m.Rename(shared.FSRenameRequest{From: "/srv", To: "/srv2"})
	wantStatus(t, err, http.StatusForbidden)

	e, err := m.Rename(shared.FSRenameRequest{From: "/srv/a", To: "/srv/c"})
	if err != nil || !e.IsDir || e.Path != "/srv/c" {
		t.Fatalf("rename: %+v %v", e, err)
	}
}

func TestFileRoutesHonourTheOptOut(t *testing.T) {
	s := &APIServer{cfg: &Config{Token: "t", DisableFiles: true}, files: newFiles(t, nil)}
	code, body := s.Dispatch("GET", "/api/fs/dir?path=/", nil)
	if code != http.StatusForbidden {
		t.Fatalf("disabled explorer answered %d %s", code, body)
	}

	s.cfg.DisableFiles = false
	code, body = s.Dispatch("GET", "/api/fs/dir?path=/", nil)
	var l shared.FSListing
	if code != 200 || json.Unmarshal(body, &l) != nil || l.Path != "/" {
		t.Fatalf("enabled explorer answered %d %s", code, body)
	}
}
