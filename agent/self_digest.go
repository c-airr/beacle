package main

import (
	"crypto/sha256"
	"encoding/hex"
	"io"
	"os"
	"path/filepath"
	"sync"
)

// selfDigest is the sha256 of the binary this agent is running, formatted the
// way GitHub reports a release asset's digest so the two compare directly.
//
// This is what makes "is there a newer agent" answerable. A version number
// cannot: a rebuild published under the same tag carries the same version and
// different bytes, so the panel called agents current while they were two
// months behind. The bytes are the only thing that cannot be wrong about
// themselves.
//
// Computed once — hashing ten megabytes at every registration would be work
// done to learn something that cannot change while the process is alive.
var selfDigest = sync.OnceValue(func() string {
	exe, err := os.Executable()
	if err != nil {
		return ""
	}
	// The service runs from a path that may be a symlink; hash what is actually
	// executing rather than the link.
	if resolved, err := filepath.EvalSymlinks(exe); err == nil {
		exe = resolved
	}

	f, err := os.Open(exe)
	if err != nil {
		return ""
	}
	defer f.Close()

	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return ""
	}
	// An empty string means "unknown", and the panel falls back to comparing
	// version numbers — never to assuming the agent is current.
	return "sha256:" + hex.EncodeToString(h.Sum(nil))
})
