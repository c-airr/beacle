//go:build !linux

package main

import (
	"os"
	"path/filepath"
)

// defaultFilesRoot gives the dev agent a sandbox that stands in for "/",
// seeded with a few files so the explorer has something to show.
func defaultFilesRoot() string {
	root := filepath.Join(os.TempDir(), "beacle-dev-fs")
	seed := map[string]string{
		"root/notes.txt":                     "dev sandbox for the file explorer\n",
		"home/deploy/bot-python/main.py":     "print('hello from the bot')\n",
		"home/deploy/bot-python/.env":        "TOKEN=dev-only\n",
		"home/deploy/app/docker-compose.yml": "services:\n  web:\n    image: nginx:alpine\n",
		"etc/hosts":                          "127.0.0.1 localhost\n",
		"var/log/syslog":                     "Oct  2 12:00:00 dev beacle-agent: started\n",
	}
	for rel, content := range seed {
		p := filepath.Join(root, filepath.FromSlash(rel))
		if _, err := os.Stat(p); err == nil {
			continue
		}
		_ = os.MkdirAll(filepath.Dir(p), 0o755)
		_ = os.WriteFile(p, []byte(content), 0o644)
	}
	return root
}

func fileOwner(os.FileInfo) string { return "" }

func fileInode(os.FileInfo) uint64 { return 0 }

func copyOwner(string, os.FileInfo) {}
