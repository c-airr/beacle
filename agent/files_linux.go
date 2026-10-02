//go:build linux

package main

import (
	"os"
	"os/user"
	"strconv"
	"sync"
	"syscall"
)

func defaultFilesRoot() string { return "" }

var ownerNames sync.Map // uid -> name

// fileOwner names the owning user, falling back to the numeric uid.
func fileOwner(info os.FileInfo) string {
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return ""
	}
	uid := strconv.FormatUint(uint64(st.Uid), 10)
	if name, ok := ownerNames.Load(uid); ok {
		return name.(string)
	}
	name := uid
	if u, err := user.LookupId(uid); err == nil {
		name = u.Username
	}
	ownerNames.Store(uid, name)
	return name
}

func fileInode(info os.FileInfo) uint64 {
	if st, ok := info.Sys().(*syscall.Stat_t); ok {
		return st.Ino
	}
	return 0
}

// copyOwner gives a replacement file the owner of the one it replaces, so
// editing /home/deploy/.env as root does not hand it over to root.
func copyOwner(name string, like os.FileInfo) {
	if st, ok := like.Sys().(*syscall.Stat_t); ok {
		_ = os.Chown(name, int(st.Uid), int(st.Gid))
	}
}
