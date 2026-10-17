package main

import (
	"cmp"
	"path"
	"slices"
	"strings"

	"beacle/shared/plugin"
)

// permNote is one line of "what this plugin can do", shown before it is
// installed and on its card. Kind names the sentence (the app translates
// it); Level is ok, info, warn or danger.
type permNote struct {
	Kind  string   `json:"kind"`
	Level string   `json:"level"`
	Items []string `json:"items,omitempty"`
}

// Read prefixes that hold passwords, keys or the agent's own token
// (/opt/beacle-agent/config.json). A prefix above one of them reaches it too.
var sensitiveDirs = []string{"/etc", "/root", "/home", "/opt", "/var", "/srv", "/boot", "/usr/local/etc"}

// Programs that run whatever they are given: listing one in permissions.exec
// is listing every command.
var anyCommand = []string{
	"sh", "bash", "dash", "zsh", "ash", "ksh", "fish", "busybox", "env", "sudo", "su", "doas", "xargs",
	"python", "python3", "perl", "ruby", "node", "php", "lua", "awk", "gawk", "find", "ssh",
}

func coversSensitive(prefix string) bool {
	p := path.Clean(prefix)
	for _, d := range sensitiveDirs {
		if p == "/" || p == d || strings.HasPrefix(p, d+"/") || strings.HasPrefix(d, p+"/") {
			return true
		}
	}
	return false
}

// reviewPermissions turns a manifest into plain sentences. It describes
// what the permissions allow, not what the code does: the permissions are
// the limit the runtime enforces, while what Lua code does can be hidden.
func reviewPermissions(m plugin.Manifest, hasAgent, hasBackend bool) []permNote {
	var out []permNote
	add := func(kind, level string, items ...string) {
		out = append(out, permNote{Kind: kind, Level: level, Items: items})
	}
	if hasAgent {
		add("agent", "info")
	}
	if hasBackend {
		add("backend", "info")
	}
	p := m.Permissions

	if slices.Contains(p.HTTP, "*") {
		add("http_any", "danger")
	} else if len(p.HTTP) > 0 {
		add("http", "warn", p.HTTP...)
	}
	urlField := slices.ContainsFunc(m.Config, func(f plugin.ConfigField) bool { return f.Type == "url" })
	if urlField {
		add("http_config", "info")
	}

	var shells, programs []string
	for _, c := range p.Exec {
		if slices.Contains(anyCommand, path.Base(c)) {
			shells = append(shells, c)
		} else {
			programs = append(programs, c)
		}
	}
	if len(shells) > 0 {
		add("exec_shell", "danger", shells...)
	}
	if len(programs) > 0 {
		add("exec", "warn", programs...)
	}

	if len(p.Write) > 0 {
		add("write", "danger", p.Write...)
	}
	var secretReads, reads []string
	for _, r := range p.Read {
		if coversSensitive(r) {
			secretReads = append(secretReads, r)
		} else {
			reads = append(reads, r)
		}
	}
	if len(secretReads) > 0 {
		add("read_sensitive", "danger", secretReads...)
	}
	if len(reads) > 0 {
		add("read", "info", reads...)
	}

	var apiRead, apiWrite []string
	for _, a := range p.API {
		if strings.HasPrefix(a, "GET ") {
			apiRead = append(apiRead, strings.TrimPrefix(a, "GET "))
		} else {
			apiWrite = append(apiWrite, a)
		}
	}
	if len(apiWrite) > 0 {
		add("api_write", "danger", apiWrite...)
	}
	if len(apiRead) > 0 {
		add("api_read", "warn", apiRead...)
	}

	var secrets []string
	for _, f := range m.Config {
		if f.Type == "secret" {
			secrets = append(secrets, cmp.Or(f.Label, f.Key))
		}
	}
	if len(secrets) > 0 {
		add("secret", "info", secrets...)
	}

	if len(p.HTTP) == 0 && !urlField && len(p.Exec) == 0 && len(p.Write) == 0 && len(p.Read) == 0 && len(p.API) == 0 {
		add("none", "ok")
	}
	return out
}
