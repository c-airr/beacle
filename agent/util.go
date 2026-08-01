package main

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// screenName rejects anything that is not a plain session name. The name lands
// in a `screen -S` argument, so this is the boundary that keeps a crafted name
// from turning into extra arguments or shell syntax.
func screenName(name string) (string, error) {
	if name == "" || len(name) > 64 {
		return "", fmt.Errorf("session name must be 1-64 characters")
	}
	for _, r := range name {
		ok := r == '-' || r == '_' || r == '.' ||
			(r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9')
		if !ok {
			return "", fmt.Errorf("session name may only contain letters, digits, dot, dash and underscore")
		}
	}
	if strings.HasPrefix(name, "-") {
		return "", fmt.Errorf("session name may not start with a dash")
	}
	return name, nil
}

// shellQuote wraps a value for safe use inside the shell string screen
// executes. Paths come from a picker, but a directory really can contain a
// quote, and the command field is free text.
func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// screenLines builds what gets typed into a screen session: a cd, then the
// command, as two independent lines — exactly what a person would type.
// Joining them with && meant a failed cd swallowed the command and the whole
// thing arrived as a single line. An empty dir means the session's own
// starting directory, so no cd is sent at all.
func screenLines(dir, command string) []string {
	var lines []string
	if dir != "" {
		lines = append(lines, "cd "+shellQuote(dir))
	}
	return append(lines, strings.TrimSpace(command))
}

func randomID() string {
	b := make([]byte, 6)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

func fetchPublicIP() string {
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Get("https://api.ipify.org")
	if err != nil {
		return ""
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}
