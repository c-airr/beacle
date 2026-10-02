package main

import (
	"bytes"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"

	"beacle/shared"
)

// File explorer. Paths on the wire are always absolute POSIX paths as the
// server sees them. root is empty in production; tests and the Windows dev
// agent point it at a sandbox directory that stands in for "/".
type FileManager struct {
	root string
}

const (
	fsReadDefault = 256 << 10
	fsReadMax     = 1 << 20
	// Matches the read cap: a chunk is base64 inside a JSON frame.
	fsChunkMax = 1 << 20
	// The editor refuses anything bigger; download it instead.
	fsTextMax    = 2 << 20
	fsPartSuffix = ".beacle-part"
)

// fsError carries the HTTP status the panel should see.
type fsError struct {
	code int
	msg  string
}

func (e *fsError) Error() string { return e.msg }

func fsBad(format string, a ...any) error {
	return &fsError{http.StatusBadRequest, fmt.Sprintf(format, a...)}
}

func fsConflict(format string, a ...any) error {
	return &fsError{http.StatusConflict, fmt.Sprintf(format, a...)}
}

// fsStatus maps an error from FileManager to an HTTP status.
func fsStatus(err error) int {
	var fe *fsError
	switch {
	case errors.As(err, &fe):
		return fe.code
	case errors.Is(err, fs.ErrNotExist):
		return http.StatusNotFound
	case errors.Is(err, fs.ErrExist):
		return http.StatusConflict
	case errors.Is(err, fs.ErrPermission):
		return http.StatusForbidden
	}
	return http.StatusInternalServerError
}

// clean validates a wire path and returns it normalised.
func (m *FileManager) clean(p string) (string, error) {
	if !strings.HasPrefix(p, "/") {
		return "", fsBad("path must be absolute")
	}
	if strings.ContainsRune(p, 0) {
		return "", fsBad("invalid path")
	}
	return path.Clean(p), nil
}

func (m *FileManager) local(p string) string {
	if m.root == "" {
		return filepath.FromSlash(p)
	}
	return filepath.Join(m.root, filepath.FromSlash(p))
}

// protected paths cannot be deleted or renamed away: "/" and every top-level
// directory (one slip there bricks the box) plus the agent's own files, so
// the panel cannot cut the branch it is sitting on.
func protectedPath(p string) bool {
	if p == "/" || strings.Count(p, "/") == 1 {
		return true
	}
	for _, own := range []string{"/opt/beacle-agent", "/var/lib/beacle", "/etc/systemd/system/beacle-agent.service"} {
		if p == own || strings.HasPrefix(p, own+"/") {
			return true
		}
	}
	return false
}

// fileVersion identifies one state of a file. Linux mtimes tick at the
// kernel's coarse clock, so two same-size saves a few ms apart can share an
// mtime; the inode tells them apart, since every atomic save gets a new one.
func fileVersion(info os.FileInfo) string {
	return strconv.FormatInt(info.ModTime().UnixNano(), 36) + "-" +
		strconv.FormatInt(info.Size(), 36) + "-" +
		strconv.FormatUint(fileInode(info), 36)
}

func (m *FileManager) entry(dir, name string, info os.FileInfo) shared.FSEntry {
	e := shared.FSEntry{
		Name:    name,
		Path:    path.Join(dir, name),
		IsDir:   info.IsDir(),
		Mode:    info.Mode().String(),
		ModTime: info.ModTime().UTC(),
		Owner:   fileOwner(info),
	}
	if info.Mode()&os.ModeSymlink != 0 {
		local := m.local(e.Path)
		if target, err := os.Readlink(local); err == nil {
			e.Link = target
		}
		if t, err := os.Stat(local); err == nil {
			info = t
			e.IsDir = t.IsDir()
		}
	}
	if !e.IsDir {
		e.Size = uint64(info.Size())
		e.Version = fileVersion(info)
	}
	return e
}

// List returns a directory, directories first. Dotfiles are skipped unless
// hidden is set.
func (m *FileManager) List(p string, hidden bool) (shared.FSListing, error) {
	if p == "" {
		p = "/root"
		if _, err := os.Stat(m.local(p)); err != nil {
			p = "/"
		}
	}
	p, err := m.clean(p)
	if err != nil {
		return shared.FSListing{}, err
	}
	items, err := os.ReadDir(m.local(p))
	if err != nil {
		return shared.FSListing{}, err
	}
	listing := shared.FSListing{Path: p, Parent: path.Dir(p), Entries: []shared.FSEntry{}}
	if p == "/" {
		listing.Parent = ""
	}
	for _, it := range items {
		if !hidden && strings.HasPrefix(it.Name(), ".") {
			continue
		}
		info, err := it.Info()
		if err != nil {
			continue // vanished between ReadDir and Info
		}
		listing.Entries = append(listing.Entries, m.entry(p, it.Name(), info))
	}
	sort.Slice(listing.Entries, func(i, j int) bool {
		a, b := listing.Entries[i], listing.Entries[j]
		if a.IsDir != b.IsDir {
			return a.IsDir
		}
		return strings.ToLower(a.Name) < strings.ToLower(b.Name)
	})
	return listing, nil
}

// Read returns up to limit bytes from offset.
func (m *FileManager) Read(p string, offset, limit int64) (shared.FSReadResponse, error) {
	p, err := m.clean(p)
	if err != nil {
		return shared.FSReadResponse{}, err
	}
	if offset < 0 {
		return shared.FSReadResponse{}, fsBad("negative offset")
	}
	if limit <= 0 {
		limit = fsReadDefault
	}
	if limit > fsReadMax {
		limit = fsReadMax
	}
	f, err := os.Open(m.local(p))
	if err != nil {
		return shared.FSReadResponse{}, err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return shared.FSReadResponse{}, err
	}
	if info.IsDir() {
		return shared.FSReadResponse{}, fsBad("%s is a directory", p)
	}
	if !info.Mode().IsRegular() {
		return shared.FSReadResponse{}, fsBad("%s is not a regular file", p)
	}
	buf := make([]byte, limit)
	n, err := f.ReadAt(buf, offset)
	if err != nil && err != io.EOF {
		return shared.FSReadResponse{}, err
	}
	buf = buf[:n]
	res := shared.FSReadResponse{
		Path:    p,
		Size:    info.Size(),
		Version: fileVersion(info),
		Offset:  offset,
		Data:    base64.StdEncoding.EncodeToString(buf),
		EOF:     offset+int64(n) >= info.Size(),
	}
	if offset == 0 {
		res.Binary = looksBinary(buf)
	}
	return res, nil
}

func looksBinary(b []byte) bool {
	if len(b) > 8<<10 {
		b = b[:8<<10]
	}
	if bytes.IndexByte(b, 0) >= 0 {
		return true
	}
	// A multi-byte rune cut by the sample boundary is not a reason to call
	// the file binary.
	for i := 0; i < 3 && len(b) > 0 && !utf8.Valid(b); i++ {
		b = b[:len(b)-1]
	}
	return !utf8.Valid(b)
}

// Write replaces a text file atomically, keeping its mode and owner. A file
// that changed since the editor loaded it (Version mismatch) is refused.
func (m *FileManager) Write(req shared.FSWriteRequest) (shared.FSEntry, error) {
	p, err := m.clean(req.Path)
	if err != nil {
		return shared.FSEntry{}, err
	}
	if len(req.Content) > fsTextMax {
		return shared.FSEntry{}, fsBad("file too large for the editor")
	}
	local := m.local(p)
	// Saving a symlinked config edits the file it points at.
	if resolved, err := filepath.EvalSymlinks(local); err == nil {
		local = resolved
	}
	mode := os.FileMode(0o644)
	info, statErr := os.Stat(local)
	switch {
	case statErr == nil:
		if info.IsDir() {
			return shared.FSEntry{}, fsBad("%s is a directory", p)
		}
		if req.Version == "" {
			return shared.FSEntry{}, fsConflict("%s already exists", p)
		}
		if fileVersion(info) != req.Version {
			return shared.FSEntry{}, fsConflict("%s changed on the server since it was opened", p)
		}
		mode = info.Mode().Perm()
	case errors.Is(statErr, fs.ErrNotExist):
		if req.Version != "" {
			return shared.FSEntry{}, fsConflict("%s was deleted on the server since it was opened", p)
		}
	default:
		return shared.FSEntry{}, statErr
	}

	tmp, err := os.CreateTemp(filepath.Dir(local), "."+filepath.Base(local)+".beacle-tmp-*")
	if err != nil {
		return shared.FSEntry{}, err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName) // no-op once renamed
	if _, err := tmp.WriteString(req.Content); err != nil {
		tmp.Close()
		return shared.FSEntry{}, err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return shared.FSEntry{}, err
	}
	if err := tmp.Close(); err != nil {
		return shared.FSEntry{}, err
	}
	if err := os.Chmod(tmpName, mode); err != nil {
		return shared.FSEntry{}, err
	}
	if info != nil {
		copyOwner(tmpName, info)
	}
	if err := os.Rename(tmpName, local); err != nil {
		return shared.FSEntry{}, err
	}
	return m.stat(p)
}

func (m *FileManager) stat(p string) (shared.FSEntry, error) {
	info, err := os.Lstat(m.local(p))
	if err != nil {
		return shared.FSEntry{}, err
	}
	return m.entry(path.Dir(p), path.Base(p), info), nil
}

// Upload appends a chunk to <path>.beacle-part. Offset must match what is
// already there, so a retried or reordered chunk cannot corrupt the file;
// on mismatch the 409 tells the panel where to resume.
func (m *FileManager) Upload(req shared.FSUploadRequest) (shared.FSUploadResponse, error) {
	p, err := m.clean(req.Path)
	if err != nil {
		return shared.FSUploadResponse{}, err
	}
	if p == "/" {
		return shared.FSUploadResponse{}, fsBad("invalid upload path")
	}
	data, err := base64.StdEncoding.DecodeString(req.Data)
	if err != nil {
		return shared.FSUploadResponse{}, fsBad("chunk is not valid base64")
	}
	if len(data) > fsChunkMax {
		return shared.FSUploadResponse{}, fsBad("chunk too large")
	}
	local := m.local(p)
	part := local + fsPartSuffix

	if info, err := os.Stat(local); err == nil {
		if info.IsDir() {
			return shared.FSUploadResponse{}, fsBad("%s is a directory", p)
		}
		// Checked on every chunk, not just the first: catching it before the
		// whole file has crossed the link is the point.
		if !req.Overwrite {
			return shared.FSUploadResponse{}, fsConflict("%s already exists", p)
		}
	}

	flags := os.O_WRONLY | os.O_CREATE
	if req.Offset == 0 {
		flags |= os.O_TRUNC
	}
	f, err := os.OpenFile(part, flags, 0o644)
	if err != nil {
		return shared.FSUploadResponse{}, err
	}
	info, err := f.Stat()
	if err != nil {
		f.Close()
		return shared.FSUploadResponse{}, err
	}
	if req.Offset != info.Size() {
		f.Close()
		return shared.FSUploadResponse{Received: info.Size()},
			fsConflict("upload offset %d does not match %d bytes received", req.Offset, info.Size())
	}
	if _, err := f.WriteAt(data, req.Offset); err != nil {
		f.Close()
		return shared.FSUploadResponse{}, err
	}
	if err := f.Close(); err != nil {
		return shared.FSUploadResponse{}, err
	}
	res := shared.FSUploadResponse{Received: req.Offset + int64(len(data))}
	if !req.Final {
		return res, nil
	}
	if err := os.Rename(part, local); err != nil {
		return shared.FSUploadResponse{}, err
	}
	e, err := m.stat(p)
	if err != nil {
		return shared.FSUploadResponse{}, err
	}
	res.Entry = &e
	return res, nil
}

func (m *FileManager) Mkdir(p string) (shared.FSEntry, error) {
	p, err := m.clean(p)
	if err != nil {
		return shared.FSEntry{}, err
	}
	if err := os.Mkdir(m.local(p), 0o755); err != nil {
		return shared.FSEntry{}, err
	}
	return m.stat(p)
}

func (m *FileManager) Rename(req shared.FSRenameRequest) (shared.FSEntry, error) {
	from, err := m.clean(req.From)
	if err != nil {
		return shared.FSEntry{}, err
	}
	to, err := m.clean(req.To)
	if err != nil {
		return shared.FSEntry{}, err
	}
	if protectedPath(from) {
		return shared.FSEntry{}, &fsError{http.StatusForbidden, from + " is protected"}
	}
	if to == from {
		return m.stat(from)
	}
	if strings.HasPrefix(to, from+"/") {
		return shared.FSEntry{}, fsBad("cannot move a directory into itself")
	}
	if _, err := os.Lstat(m.local(to)); err == nil {
		if !req.Overwrite {
			return shared.FSEntry{}, fsConflict("%s already exists", to)
		}
	} else if !errors.Is(err, fs.ErrNotExist) {
		return shared.FSEntry{}, err
	}
	if err := os.Rename(m.local(from), m.local(to)); err != nil {
		return shared.FSEntry{}, err
	}
	return m.stat(to)
}

// Delete removes a file, a symlink (never what it points at) or a directory.
// A non-empty directory needs Recursive.
func (m *FileManager) Delete(req shared.FSPathRequest) error {
	p, err := m.clean(req.Path)
	if err != nil {
		return err
	}
	if protectedPath(p) {
		return &fsError{http.StatusForbidden, p + " is protected"}
	}
	local := m.local(p)
	info, err := os.Lstat(local)
	if err != nil {
		return err
	}
	if info.IsDir() && req.Recursive {
		return os.RemoveAll(local)
	}
	if err := os.Remove(local); err != nil {
		if info.IsDir() {
			if items, rerr := os.ReadDir(local); rerr == nil && len(items) > 0 {
				return fsConflict("%s is not empty", p)
			}
		}
		return err
	}
	return nil
}
