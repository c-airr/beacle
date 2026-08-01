package main

import (
	"strings"
)

// caddyBlock is one top-level site block lifted out of a Caddyfile, kept as
// both structured hints and the original text. The text matters: anything the
// panel cannot model has to survive a round trip untouched.
type caddyBlock struct {
	Addresses []string // e.g. ["discordbothosting.pl", "www.discordbothosting.pl"]
	Body      string   // inside the braces, original formatting
	Raw       string   // the whole block including the address line
}

// stripComments removes `#` comments that are not inside a quoted string.
// Caddy placeholders like {path} are not quotes, so only " matters here.
func stripComments(line string) string {
	inQuote := false
	for i := 0; i < len(line); i++ {
		switch line[i] {
		case '"':
			// A backslash-escaped quote stays inside the string.
			if i == 0 || line[i-1] != '\\' {
				inQuote = !inQuote
			}
		case '#':
			if !inQuote {
				return line[:i]
			}
		}
	}
	return line
}

// parseCaddyfile splits a Caddyfile into its top-level site blocks. It counts
// braces outside quotes, which is enough for real configs: nested handle /
// header / matcher blocks come back inside Body untouched.
func parseCaddyfile(src string) []caddyBlock {
	var blocks []caddyBlock

	lines := strings.Split(src, "\n")
	var header []string // address line(s) collected before the opening brace
	var body []string
	var raw []string
	depth := 0

	for _, line := range lines {
		code := strings.TrimSpace(stripComments(line))

		if depth == 0 {
			if code == "" {
				continue
			}
			// A block opens on the line carrying its first unquoted '{'.
			open := strings.Count(code, "{") - strings.Count(code, "}")
			// Caddy placeholders ({path}) are balanced, so they net to zero and
			// never look like a block opening.
			if open > 0 {
				addr := strings.TrimSpace(code[:strings.Index(code, "{")])
				header = splitAddresses(addr)
				depth = open
				raw = []string{line}
				body = nil
				continue
			}
			// Global options block or a stray directive — skip it.
			continue
		}

		raw = append(raw, line)
		delta := strings.Count(code, "{") - strings.Count(code, "}")
		depth += delta
		if depth <= 0 {
			blocks = append(blocks, caddyBlock{
				Addresses: header,
				Body:      strings.Join(body, "\n"),
				Raw:       strings.Join(raw, "\n"),
			})
			depth = 0
			header, body, raw = nil, nil, nil
			continue
		}
		body = append(body, line)
	}
	return blocks
}

// splitAddresses turns "a.com, www.a.com" into its parts, dropping empties.
func splitAddresses(addr string) []string {
	var out []string
	for _, part := range strings.Split(addr, ",") {
		if p := strings.TrimSpace(part); p != "" {
			out = append(out, p)
		}
	}
	return out
}

// directiveArg finds the first occurrence of a directive at any nesting depth
// and returns its argument, e.g. reverse_proxy → "localhost:18080".
func directiveArg(body, directive string) string {
	for _, line := range strings.Split(body, "\n") {
		f := strings.Fields(strings.TrimSpace(stripComments(line)))
		if len(f) >= 2 && f[0] == directive {
			arg := f[1]
			// `reverse_proxy localhost:8080 {` — drop a trailing brace.
			if arg == "{" {
				continue
			}
			return strings.TrimSuffix(arg, "{")
		}
	}
	return ""
}

// hasDirective reports whether a bare directive appears at any depth.
func hasDirective(body, directive string) bool {
	for _, line := range strings.Split(body, "\n") {
		f := strings.Fields(strings.TrimSpace(stripComments(line)))
		if len(f) >= 1 && strings.TrimSuffix(f[0], "{") == directive {
			return true
		}
	}
	return false
}

// caddySiteKind classifies what a block actually does, which is what decides
// whether the form can safely represent it.
const (
	siteKindProxy  = "proxy"  // reverse_proxy only
	siteKindStatic = "static" // root/file_server only
	siteKindMixed  = "mixed"  // both, e.g. an SPA with an /api matcher
	siteKindOther  = "other"
)

func classifyBlock(body string) string {
	proxy := hasDirective(body, "reverse_proxy")
	static := hasDirective(body, "file_server") || hasDirective(body, "root")
	switch {
	case proxy && static:
		return siteKindMixed
	case proxy:
		return siteKindProxy
	case static:
		return siteKindStatic
	default:
		return siteKindOther
	}
}

// editableByForm reports whether the site editor can regenerate this block
// without losing anything. Everything the form does not model — matchers,
// handle blocks, try_files, php_fastcgi, redirects, rewrites, multiple
// domains — makes the block read-only, because saving would silently replace
// a working config with a plainer one.
func editableByForm(b caddyBlock) bool {
	if len(b.Addresses) != 1 {
		return false
	}
	if classifyBlock(b.Body) != siteKindProxy {
		return false
	}
	unsupported := []string{
		"handle", "handle_path", "route", "try_files", "file_server", "root",
		"rewrite", "redir", "php_fastcgi", "templates", "respond", "map",
		"forward_auth", "reverse_proxy_to", "import", "uri", "vars",
	}
	for _, line := range strings.Split(b.Body, "\n") {
		trimmed := strings.TrimSpace(stripComments(line))
		if trimmed == "" {
			continue
		}
		// A named matcher (@api ...) means path-based routing the form cannot express.
		if strings.HasPrefix(trimmed, "@") {
			return false
		}
		first := strings.TrimSuffix(strings.Fields(trimmed)[0], "{")
		for _, u := range unsupported {
			if first == u {
				return false
			}
		}
	}
	return true
}

// tlsMode reports how the block gets its certificate, which the panel shows
// because "tls internal" behind Cloudflare looks like a broken cert otherwise.
func tlsMode(b caddyBlock) string {
	arg := directiveArg(b.Body, "tls")
	switch {
	case arg == "internal":
		return "internal"
	case arg != "":
		return "custom"
	case len(b.Addresses) > 0 && strings.HasPrefix(b.Addresses[0], "http://"):
		return "none"
	default:
		return "auto"
	}
}
