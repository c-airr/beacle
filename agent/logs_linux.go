//go:build linux

package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"

	"beacle/shared"
)

// System logs, the ones every admin reaches for first. Sources resolve at
// call time because distros disagree on paths (syslog vs messages, auth.log
// vs secure) and log files come and go with rotation.
type logSource struct {
	id    string
	label string
	// files are tried in order, first existing wins.
	files []string
	// globDir expands to one entry per matching file (proxy logs).
	globDir     string
	globPattern string
	// command, when set, runs instead of reading a file (dmesg).
	command []string
}

var systemLogSources = []logSource{
	{id: "syslog", label: "System log", files: []string{"/var/log/syslog", "/var/log/messages"}},
	{id: "auth", label: "Auth log", files: []string{"/var/log/auth.log", "/var/log/secure"}},
	{id: "dmesg", label: "Kernel ring buffer", command: []string{"dmesg", "--time-format=iso"}},
	{id: "caddy", label: "Caddy", globDir: "/var/log/caddy", globPattern: "*.log"},
	{id: "nginx", label: "Nginx", globDir: "/var/log/nginx", globPattern: "*.log"},
}

const (
	systemLogMaxTail  = 2000
	systemLogMaxBytes = 512 << 10
)

func (c *linuxCollector) SystemLogFiles() ([]shared.SystemLogFile, error) {
	var out []shared.SystemLogFile
	for _, src := range systemLogSources {
		switch {
		case len(src.command) > 0:
			if _, err := exec.LookPath(src.command[0]); err == nil {
				out = append(out, shared.SystemLogFile{ID: src.id, Label: src.label, Path: strings.Join(src.command, " ")})
			}
		case src.globDir != "":
			matches, _ := filepath.Glob(filepath.Join(src.globDir, src.globPattern))
			sort.Strings(matches)
			for _, m := range matches {
				// Cap the picker: a host with years of rotated logs would
				// otherwise list hundreds of entries.
				if len(out) >= 40 {
					break
				}
				out = append(out, shared.SystemLogFile{
					ID:    src.id + ":" + filepath.Base(m),
					Label: src.label + " / " + filepath.Base(m),
					Path:  m,
				})
			}
		default:
			for _, f := range src.files {
				if st, err := os.Stat(f); err == nil && !st.IsDir() {
					out = append(out, shared.SystemLogFile{ID: src.id, Label: src.label, Path: f})
					break
				}
			}
		}
	}
	return out, nil
}

// resolveLogID maps a client-supplied ID back to its source. Only IDs the
// agent itself advertised resolve — anything else is refused, so the panel
// can never talk the agent into reading an arbitrary path.
func resolveLogID(id string) (logSource, string, error) {
	base, extra, _ := strings.Cut(id, ":")
	for _, src := range systemLogSources {
		if src.id != base {
			continue
		}
		switch {
		case len(src.command) > 0:
			if extra != "" {
				break
			}
			return src, "", nil
		case src.globDir != "":
			if extra == "" || strings.ContainsAny(extra, "/\\") {
				break
			}
			p := filepath.Join(src.globDir, extra)
			if !strings.HasSuffix(p, ".log") {
				break
			}
			if st, err := os.Stat(p); err != nil || st.IsDir() {
				break
			}
			return src, p, nil
		default:
			if extra != "" {
				break
			}
			for _, f := range src.files {
				if st, err := os.Stat(f); err == nil && !st.IsDir() {
					return src, f, nil
				}
			}
		}
	}
	return logSource{}, "", fmt.Errorf("unknown log %q", id)
}

func (c *linuxCollector) SystemLogs(id string, tail int, grep string) (string, error) {
	if tail <= 0 {
		tail = 400
	}
	if tail > systemLogMaxTail {
		tail = systemLogMaxTail
	}
	src, path, err := resolveLogID(id)
	if err != nil {
		return "", err
	}

	var text string
	if len(src.command) > 0 {
		out, err := exec.Command(src.command[0], src.command[1:]...).Output()
		if err != nil {
			// --time-format needs a newer util-linux; retry plain.
			out, err = exec.Command(src.command[0]).Output()
			if err != nil {
				return "", err
			}
		}
		text = string(out)
	} else {
		b, err := os.ReadFile(path)
		if err != nil {
			return "", err
		}
		if len(b) > systemLogMaxBytes {
			b = b[len(b)-systemLogMaxBytes:]
			if i := strings.IndexByte(string(b), '\n'); i >= 0 {
				b = b[i+1:]
			}
		}
		text = string(b)
	}

	lines := strings.Split(text, "\n")
	if grep = strings.TrimSpace(grep); grep != "" {
		lower := strings.ToLower(grep)
		kept := lines[:0]
		for _, l := range lines {
			if strings.Contains(strings.ToLower(l), lower) {
				kept = append(kept, l)
			}
		}
		lines = kept
	}
	if len(lines) > tail {
		lines = lines[len(lines)-tail:]
	}
	out := strings.Join(lines, "\n")
	if len(out) > systemLogMaxBytes {
		out = out[len(out)-systemLogMaxBytes:]
	}
	return out, nil
}
