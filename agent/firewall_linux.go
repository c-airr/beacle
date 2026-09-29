//go:build linux

package main

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"beacle/shared"
)

// Firewall management with an SSH guard. Backends are picked in order:
// ufw → firewalld → iptables (which on modern distros fronts nftables via
// the compatibility wrapper, so it covers "nft" systems with a stable CLI).
// A host with only the raw nft CLI gets a read-only listing — inventing our
// own table there would either do nothing (no jump from the base chain) or
// fight the admin's ruleset, and a firewall tool must never do either.
//
// The guard: SSH ports (sshd config + live sessions, 22 always) and the
// agent's own port can never be denied to the world, and deleting an allow
// that covers them needs an explicit force. Everything is validated again at
// apply time, not just in the panel.

var fwMu sync.Mutex

const (
	fwBackendNone      = "none"
	fwBackendUFW       = "ufw"
	fwBackendFirewalld = "firewalld"
	fwBackendIptables  = "iptables"
	fwBackendNFT       = "nftables"
)

func detectFirewall() string {
	if _, err := exec.LookPath("ufw"); err == nil {
		return fwBackendUFW
	}
	if _, err := exec.LookPath("firewall-cmd"); err == nil {
		return fwBackendFirewalld
	}
	if _, err := exec.LookPath("iptables"); err == nil {
		return fwBackendIptables
	}
	if _, err := exec.LookPath("nft"); err == nil {
		return fwBackendNFT
	}
	return fwBackendNone
}

// --- spec validation ---------------------------------------------------------

func parseFWPort(port string) (lo, hi int, multi []int, err error) {
	port = strings.TrimSpace(port)
	if port == "" {
		return 0, 0, nil, fmt.Errorf("port is empty")
	}
	if strings.Contains(port, ",") {
		// Display-only shape (ufw prints "80,443/tcp"); specs take one range.
		return 0, 0, nil, fmt.Errorf("one port or range at a time, got %q", port)
	}
	sep := ""
	if strings.Contains(port, ":") {
		sep = ":"
	} else if strings.Contains(port, "-") {
		sep = "-"
	}
	one := func(s string) (int, error) {
		n, err := strconv.Atoi(strings.TrimSpace(s))
		if err != nil || n < 1 || n > 65535 {
			return 0, fmt.Errorf("bad port %q", s)
		}
		return n, nil
	}
	if sep == "" {
		n, err := one(port)
		return n, n, nil, err
	}
	parts := strings.SplitN(port, sep, 2)
	lo, err = one(parts[0])
	if err != nil {
		return 0, 0, nil, err
	}
	hi, err = one(parts[1])
	if err != nil {
		return 0, 0, nil, err
	}
	if lo >= hi {
		return 0, 0, nil, fmt.Errorf("bad range %q", port)
	}
	return lo, hi, nil, nil
}

// fwPortCovers reports whether a rule/display port expression covers p. It
// accepts backend display shapes too (comma lists, dash or colon ranges).
func fwPortCovers(expr string, p int) bool {
	expr = strings.TrimSpace(expr)
	if expr == "" {
		return true // unscoped rule covers everything
	}
	for _, part := range strings.Split(expr, ",") {
		part = strings.TrimSpace(part)
		sep := ""
		if strings.Contains(part, ":") {
			sep = ":"
		} else if strings.Contains(part, "-") {
			sep = "-"
		}
		if sep == "" {
			if n, err := strconv.Atoi(part); err == nil && n == p {
				return true
			}
			continue
		}
		b := strings.SplitN(part, sep, 2)
		lo, err1 := strconv.Atoi(strings.TrimSpace(b[0]))
		hi, err2 := strconv.Atoi(strings.TrimSpace(b[1]))
		if err1 == nil && err2 == nil && p >= lo && p <= hi {
			return true
		}
	}
	return false
}

func sanitizeFWComment(s string) string {
	s = strings.Map(func(r rune) rune {
		if r == '\n' || r == '\r' {
			return -1
		}
		return r
	}, strings.TrimSpace(s))
	if len(s) > 64 {
		s = s[:64]
	}
	return s
}

func validateFWSpec(spec shared.FirewallRuleSpec) (shared.FirewallRuleSpec, error) {
	spec.Action = strings.ToLower(strings.TrimSpace(spec.Action))
	spec.Proto = strings.ToLower(strings.TrimSpace(spec.Proto))
	spec.Port = strings.TrimSpace(spec.Port)
	spec.Source = strings.TrimSpace(spec.Source)
	spec.Comment = sanitizeFWComment(spec.Comment)
	if spec.Action != "allow" && spec.Action != "deny" {
		return spec, fmt.Errorf("action must be allow or deny")
	}
	if spec.Proto != "tcp" && spec.Proto != "udp" {
		return spec, fmt.Errorf("proto must be tcp or udp")
	}
	if spec.Source != "" {
		if net.ParseIP(spec.Source) == nil {
			if _, _, err := net.ParseCIDR(spec.Source); err != nil {
				return spec, fmt.Errorf("bad source %q: not an IP or CIDR", spec.Source)
			}
		}
	}
	if spec.Port == "" {
		// A port-less rule is a whole-IP verdict — meaningful only as a
		// scoped deny. Anything else is a firewall off-switch by typo.
		if spec.Action != "deny" || spec.Source == "" {
			return spec, fmt.Errorf("port is required (a rule with neither port nor source is allow/deny-all)")
		}
		return spec, nil
	}
	if _, _, _, err := parseFWPort(spec.Port); err != nil {
		return spec, err
	}
	return spec, nil
}

// --- SSH guard ----------------------------------------------------------------

func sshdPorts() []int {
	set := map[int]bool{22: true}
	files := []string{"/etc/ssh/sshd_config"}
	// Includes first, so the main file's values are seen too — everything
	// collected is protected, order does not matter for a guard.
	if raw, err := os.ReadFile("/etc/ssh/sshd_config"); err == nil {
		for _, line := range strings.Split(string(raw), "\n") {
			line = strings.TrimSpace(line)
			if i := strings.Index(line, "#"); i >= 0 {
				line = strings.TrimSpace(line[:i])
			}
			fields := strings.Fields(line)
			if len(fields) >= 2 && strings.EqualFold(fields[0], "Include") {
				for _, pat := range fields[1:] {
					matches, _ := filepath.Glob(pat)
					files = append(files, matches...)
				}
			}
		}
	}
	for _, f := range files {
		raw, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		for _, line := range strings.Split(string(raw), "\n") {
			if i := strings.Index(line, "#"); i >= 0 {
				line = line[:i]
			}
			fields := strings.Fields(line)
			if len(fields) >= 2 && strings.EqualFold(fields[0], "Port") {
				for _, v := range fields[1:] {
					if n, err := strconv.Atoi(v); err == nil && n >= 1 && n <= 65535 {
						set[n] = true
					}
				}
			}
		}
	}
	var out []int
	for p := range set {
		out = append(out, p)
	}
	sort.Ints(out)
	return out
}

// sshdSessionPorts finds the local ports of live sshd connections — the
// sessions an admin is actually sitting in right now.
func sshdSessionPorts() []int {
	raw, err := exec.Command("ss", "-tnp", "state", "established").Output()
	if err != nil {
		return nil
	}
	set := map[int]bool{}
	for _, line := range strings.Split(string(raw), "\n") {
		if !strings.Contains(line, `"sshd"`) && !strings.Contains(line, "sshd,") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 5 {
			continue
		}
		_, port := splitListenAddr(fields[3])
		if port > 0 {
			set[port] = true
		}
	}
	var out []int
	for p := range set {
		out = append(out, p)
	}
	return out
}

func (c *linuxCollector) protectedPorts() []int {
	set := map[int]bool{}
	for _, p := range sshdPorts() {
		set[p] = true
	}
	for _, p := range sshdSessionPorts() {
		set[p] = true
	}
	// The agent talks to the backend over an outbound tunnel, so no INPUT
	// rule can sever it — but the listen port stays guarded anyway. If the
	// panel ever reaches the agent directly, that path must keep working.
	if c.cfg != nil && c.cfg.ListenPort > 0 {
		set[c.cfg.ListenPort] = true
	} else {
		set[8931] = true
	}
	var out []int
	for p := range set {
		out = append(out, p)
	}
	sort.Ints(out)
	return out
}

func guardDeny(spec shared.FirewallRuleSpec, protected []int) (string, error) {
	touches := func() int {
		for _, p := range protected {
			if fwPortCovers(spec.Port, p) {
				return p
			}
		}
		return 0
	}
	if spec.Port == "" {
		// Whole-IP block: validation already forced a source. Legitimate
		// (blocking an attacker), but say it out loud.
		return fmt.Sprintf("blocks ALL ports including SSH for %s", spec.Source), nil
	}
	if p := touches(); p > 0 && spec.Source == "" {
		return "", fmt.Errorf("refusing to deny protected port %d to the whole world (ssh/agent guard)", p)
	}
	if p := touches(); p > 0 {
		return fmt.Sprintf("touches protected port %d (ssh/agent) for %s", p, spec.Source), nil
	}
	return "", nil
}

// --- status ---------------------------------------------------------------------

func (c *linuxCollector) FirewallStatus() (shared.FirewallStatus, error) {
	st := shared.FirewallStatus{Backend: detectFirewall()}
	st.ProtectedPorts = c.protectedPorts()
	if ports, err := c.Ports(); err == nil {
		st.OpenPorts = ports
	}
	switch st.Backend {
	case fwBackendUFW:
		return st, ufwStatus(&st)
	case fwBackendFirewalld:
		return st, firewalldStatus(&st)
	case fwBackendIptables:
		return st, iptablesStatus(&st)
	case fwBackendNFT:
		return st, nftStatus(&st)
	default:
		st.Note = "no supported firewall found (looked for ufw, firewalld, iptables, nft)"
		return st, nil
	}
}

func markProtectedRules(st *shared.FirewallStatus) {
	for i := range st.Rules {
		r := &st.Rules[i]
		if r.ID == "" || r.Action != "allow" {
			continue
		}
		// Proto is ignored on purpose: a tcp allow on 22 guards the ssh
		// port even if some backend reports the rule as "any".
		for _, p := range st.ProtectedPorts {
			if fwPortCovers(r.Port, p) {
				r.Protected = true
				break
			}
		}
	}
}

// --- ufw --------------------------------------------------------------------------

var ufwNumRe = regexp.MustCompile(`^\[\s*(\d+)\]`)

func ufwStatus(st *shared.FirewallStatus) error {
	st.Editable = true
	out, err := runCmd(15*time.Second, "ufw", "status", "numbered")
	if err != nil {
		return fmt.Errorf("ufw status: %v", err)
	}
	lines := strings.Split(out, "\n")
	if len(lines) > 0 && strings.Contains(strings.ToLower(lines[0]), "status: active") {
		st.Enabled = true
	}
	if v, err := runCmd(15*time.Second, "ufw", "status", "verbose"); err == nil {
		for _, l := range strings.Split(strings.ToLower(v), "\n") {
			if strings.Contains(l, "default:") {
				if strings.Contains(l, "deny (incoming)") {
					st.DefaultIncoming = "deny"
				} else if strings.Contains(l, "allow (incoming)") {
					st.DefaultIncoming = "allow"
				}
				break
			}
		}
	}
	cols := regexp.MustCompile(`\s{2,}`)
	for _, l := range lines {
		m := ufwNumRe.FindStringSubmatch(l)
		if m == nil {
			continue
		}
		rest := strings.TrimSpace(l[len(m[0]):])
		parts := cols.Split(rest, 3)
		if len(parts) < 3 {
			parts = strings.Fields(rest)
			if len(parts) < 3 {
				continue
			}
			parts = []string{parts[0], strings.Join(parts[1:len(parts)-1], " "), parts[len(parts)-1]}
		}
		to, action, from := strings.TrimSpace(parts[0]), strings.ToUpper(strings.TrimSpace(parts[1])), strings.TrimSpace(parts[2])
		rule := shared.FirewallRule{ID: m[1], Raw: strings.TrimSpace(l)}
		switch {
		case strings.HasPrefix(action, "ALLOW"), strings.HasPrefix(action, "LIMIT"):
			rule.Action = "allow"
		case strings.HasPrefix(action, "DENY"), strings.HasPrefix(action, "REJECT"):
			rule.Action = "deny"
		default:
			rule.Action = "other"
		}
		if !strings.EqualFold(to, "Anywhere") {
			// "22/tcp", "80,443/tcp", "8000:8010/udp" or bare "22".
			rule.Proto = "any"
			pp := to
			if i := strings.LastIndex(pp, "/"); i >= 0 {
				rule.Proto = strings.ToLower(pp[i+1:])
				pp = pp[:i]
			}
			rule.Port = pp
		} else {
			rule.Proto = "any"
		}
		if !strings.HasPrefix(strings.ToLower(from), "anywhere") {
			rule.Source = strings.Fields(from)[0]
		}
		st.Rules = append(st.Rules, rule)
	}
	markProtectedRules(st)
	return nil
}

func ufwCommands(verb string, spec shared.FirewallRuleSpec) []string {
	port := strings.ReplaceAll(spec.Port, "-", ":")
	var argv []string
	pp := port + "/" + spec.Proto
	switch {
	case spec.Port == "":
		argv = []string{"ufw", verb, "from", spec.Source}
	case spec.Source == "":
		argv = []string{"ufw", verb, pp}
	default:
		argv = []string{"ufw", verb, "from", spec.Source, "to", "any", "port", port, "proto", spec.Proto}
	}
	if spec.Comment != "" {
		argv = append(argv, "comment", spec.Comment)
	}
	return []string{shellJoin(argv)}
}

func ufwRun(spec shared.FirewallRuleSpec, allow bool) error {
	verb := "deny"
	if allow {
		verb = "allow"
	}
	port := strings.ReplaceAll(spec.Port, "-", ":")
	var args []string
	pp := port + "/" + spec.Proto
	switch {
	case spec.Port == "":
		args = []string{verb, "from", spec.Source}
	case spec.Source == "":
		args = []string{verb, pp}
	default:
		args = []string{verb, "from", spec.Source, "to", "any", "port", port, "proto", spec.Proto}
	}
	if spec.Comment != "" {
		args = append(args, "comment", spec.Comment)
	}
	out, err := runCmd(30*time.Second, "ufw", args...)
	if err != nil {
		return fmt.Errorf("ufw %s: %s", verb, firstLine(out))
	}
	return nil
}

func ufwDelete(id string) error {
	if _, err := strconv.Atoi(id); err != nil {
		return fmt.Errorf("bad ufw rule number %q", id)
	}
	out, err := runCmd(30*time.Second, "ufw", "--force", "delete", id)
	if err != nil {
		return fmt.Errorf("ufw delete: %s", firstLine(out))
	}
	return nil
}

// --- firewalld --------------------------------------------------------------------

func firewalldZone() string {
	out, err := runCmd(10*time.Second, "firewall-cmd", "--get-default-zone")
	if err != nil {
		return "public"
	}
	if z := strings.TrimSpace(out); z != "" {
		return z
	}
	return "public"
}

func parseFwRichRule(raw string) shared.FirewallRule {
	r := shared.FirewallRule{Proto: "any", Raw: raw}
	srcRe := regexp.MustCompile(`source address="([^"]+)"`)
	portRe := regexp.MustCompile(`port port="([^"]+)" protocol="([^"]+)"`)
	svcRe := regexp.MustCompile(`service name="([^"]+)"`)
	if m := srcRe.FindStringSubmatch(raw); m != nil {
		r.Source = m[1]
	}
	if m := portRe.FindStringSubmatch(raw); m != nil {
		r.Port = strings.ReplaceAll(m[1], "-", ":")
		r.Proto = strings.ToLower(m[2])
	} else if m := svcRe.FindStringSubmatch(raw); m != nil {
		r.Comment = "service " + m[1]
	}
	low := strings.ToLower(strings.TrimSpace(raw))
	switch {
	case strings.HasSuffix(low, "accept"):
		r.Action = "allow"
	case strings.HasSuffix(low, "reject"), strings.HasSuffix(low, "drop"):
		r.Action = "deny"
	default:
		r.Action = "other"
	}
	return r
}

func firewalldStatus(st *shared.FirewallStatus) error {
	st.Editable = true
	zone := firewalldZone()
	st.BackendDetail = "zone " + zone
	if out, err := runCmd(10*time.Second, "firewall-cmd", "--state"); err == nil {
		st.Enabled = strings.TrimSpace(out) == "running"
	}
	// firewalld defaults to deny-incoming on public; the target is explicit.
	if out, err := runCmd(10*time.Second, "firewall-cmd", "--zone="+zone, "--get-target"); err == nil {
		switch strings.ToLower(strings.TrimSpace(out)) {
		case "accept":
			st.DefaultIncoming = "allow"
		case "drop", "%%reject%%", "reject":
			st.DefaultIncoming = "deny"
		}
	}
	if out, err := runCmd(15*time.Second, "firewall-cmd", "--zone="+zone, "--list-services"); err == nil {
		for _, s := range strings.Fields(out) {
			st.Rules = append(st.Rules, shared.FirewallRule{
				Action: "allow", Proto: "any", Comment: "service " + s,
				Raw: "service: " + s,
			})
		}
	}
	if out, err := runCmd(15*time.Second, "firewall-cmd", "--zone="+zone, "--list-ports"); err == nil {
		for _, p := range strings.Fields(out) {
			proto := "tcp"
			port := p
			if i := strings.LastIndex(p, "/"); i >= 0 {
				port, proto = p[:i], strings.ToLower(p[i+1:])
			}
			st.Rules = append(st.Rules, shared.FirewallRule{
				ID: "port:" + p, Action: "allow", Proto: proto,
				Port: strings.ReplaceAll(port, "-", ":"), Raw: p,
			})
		}
	}
	if out, err := runCmd(15*time.Second, "firewall-cmd", "--zone="+zone, "--list-rich-rules"); err == nil {
		idx := 0
		for _, l := range strings.Split(out, "\n") {
			l = strings.TrimSpace(l)
			if l == "" {
				continue
			}
			r := parseFwRichRule(l)
			r.ID = "rich:" + strconv.Itoa(idx)
			idx++
			st.Rules = append(st.Rules, r)
		}
	}
	markProtectedRules(st)
	return nil
}

func fwRichRule(spec shared.FirewallRuleSpec, allow bool) string {
	verdict := "drop"
	if allow {
		verdict = "accept"
	}
	family := "ipv4"
	if strings.Contains(spec.Source, ":") {
		family = "ipv6"
	}
	var b strings.Builder
	fmt.Fprintf(&b, `rule family="%s"`, family)
	if spec.Source != "" {
		fmt.Fprintf(&b, ` source address="%s"`, spec.Source)
	}
	if spec.Port != "" {
		lo, hi, _, _ := parseFWPort(spec.Port)
		port := strconv.Itoa(lo)
		if hi != lo {
			port = fmt.Sprintf("%d-%d", lo, hi)
		}
		fmt.Fprintf(&b, ` port port="%s" protocol="%s"`, port, spec.Proto)
	}
	fmt.Fprintf(&b, ` %s`, verdict)
	return b.String()
}

func firewalldRun(spec shared.FirewallRuleSpec, allow bool) error {
	zone := firewalldZone()
	var args []string
	if spec.Port != "" && spec.Source == "" {
		lo, hi, _, _ := parseFWPort(spec.Port)
		port := strconv.Itoa(lo)
		if hi != lo {
			port = fmt.Sprintf("%d-%d", lo, hi)
		}
		if allow {
			args = []string{"--permanent", "--zone=" + zone, "--add-port=" + port + "/" + spec.Proto}
		} else {
			// firewalld has no bare deny-port: a rich drop rule does it.
			args = []string{"--permanent", "--zone=" + zone, "--add-rich-rule=" + fwRichRule(spec, false)}
		}
	} else {
		args = []string{"--permanent", "--zone=" + zone, "--add-rich-rule=" + fwRichRule(spec, allow)}
	}
	if out, err := runCmd(30*time.Second, "firewall-cmd", args...); err != nil {
		return fmt.Errorf("firewall-cmd: %s", firstLine(out))
	}
	if out, err := runCmd(30*time.Second, "firewall-cmd", "--reload"); err != nil {
		return fmt.Errorf("firewall-cmd reload: %s", firstLine(out))
	}
	return nil
}

func firewalldDelete(zone, id string) (string, error) {
	if strings.HasPrefix(id, "port:") {
		return fmt.Sprintf("--remove-port=%s", strings.TrimPrefix(id, "port:")), nil
	}
	if strings.HasPrefix(id, "rich:") {
		n, err := strconv.Atoi(strings.TrimPrefix(id, "rich:"))
		if err != nil || n < 0 {
			return "", fmt.Errorf("bad rule id %q", id)
		}
		out, err := runCmd(15*time.Second, "firewall-cmd", "--zone="+zone, "--list-rich-rules")
		if err != nil {
			return "", err
		}
		var rules []string
		for _, l := range strings.Split(out, "\n") {
			if l = strings.TrimSpace(l); l != "" {
				rules = append(rules, l)
			}
		}
		if n >= len(rules) {
			return "", fmt.Errorf("rule %q no longer exists — reload and retry", id)
		}
		return "--remove-rich-rule=" + rules[n], nil
	}
	return "", fmt.Errorf("rule %q cannot be deleted here", id)
}

// --- iptables ------------------------------------------------------------------------

func iptablesStatus(st *shared.FirewallStatus) error {
	st.Editable = true
	if out, err := runCmd(3*time.Second, "iptables", "--version"); err == nil && strings.Contains(out, "nf_tables") {
		st.BackendDetail = "iptables over nf_tables"
	}
	out, err := runCmd(15*time.Second, "iptables", "-S", "INPUT", "--line-numbers")
	if err != nil {
		return fmt.Errorf("iptables: %v", err)
	}
	st.Enabled = true // no daemon to be down; the chain is the firewall
	for _, l := range strings.Split(out, "\n") {
		l = strings.TrimSpace(l)
		if strings.HasPrefix(l, "-P INPUT") {
			switch {
			case strings.Contains(l, "DROP"), strings.Contains(l, "REJECT"):
				st.DefaultIncoming = "deny"
			case strings.Contains(l, "ACCEPT"):
				st.DefaultIncoming = "allow"
			}
			continue
		}
		if !strings.HasPrefix(l, "-A INPUT ") && !strings.HasPrefix(l, "-I INPUT ") {
			continue
		}
		r, ok := parseIptablesLine(l)
		if !ok {
			continue
		}
		st.Rules = append(st.Rules, r)
	}
	if _, err := exec.LookPath("netfilter-persistent"); err != nil {
		if _, err := exec.LookPath("iptables-save"); err == nil {
			st.Note = "IPv4 only. Rules do not survive reboot — install iptables-persistent (netfilter-persistent save)."
		} else {
			st.Note = "IPv4 only."
		}
	}
	markProtectedRules(st)
	return nil
}

func parseIptablesLine(line string) (shared.FirewallRule, bool) {
	r := shared.FirewallRule{Proto: "any", Raw: line}
	fields := strings.Fields(line)
	// -A INPUT <num> ... / -I INPUT ...
	if len(fields) < 4 || (fields[0] != "-A" && fields[0] != "-I") || fields[1] != "INPUT" {
		return r, false
	}
	i := 2
	if n, err := strconv.Atoi(fields[2]); err == nil {
		r.ID = strconv.Itoa(n)
		i = 3
	} else {
		return r, false
	}
	for ; i < len(fields); i++ {
		switch fields[i] {
		case "-p":
			if i+1 < len(fields) {
				r.Proto = strings.ToLower(fields[i+1])
				i++
			}
		case "-s":
			if i+1 < len(fields) {
				r.Source = fields[i+1]
				i++
			}
		case "--dport", "--dports":
			if i+1 < len(fields) {
				r.Port = fields[i+1]
				i++
			}
		case "-j":
			if i+1 < len(fields) {
				switch strings.ToUpper(fields[i+1]) {
				case "ACCEPT":
					r.Action = "allow"
				case "DROP", "REJECT":
					r.Action = "deny"
				default:
					r.Action = "other"
				}
				i++
			}
		case "--comment":
			if i+1 < len(fields) {
				r.Comment = strings.Trim(fields[i+1], `"'`)
				i++
			}
		}
	}
	if r.Action == "" {
		r.Action = "other"
	}
	return r, true
}

func iptablesArgs(spec shared.FirewallRuleSpec, allow bool) []string {
	target := "DROP"
	if allow {
		target = "ACCEPT"
	}
	args := []string{"-A", "INPUT"}
	if spec.Source != "" {
		args = append(args, "-s", spec.Source)
	}
	if spec.Port != "" {
		args = append(args, "-p", spec.Proto, "-m", spec.Proto, "--dport",
			strings.ReplaceAll(spec.Port, "-", ":"))
	}
	args = append(args, "-j", target)
	if spec.Comment != "" {
		args = append(args, "-m", "comment", "--comment", spec.Comment)
	} else {
		args = append(args, "-m", "comment", "--comment", "beacle")
	}
	return args
}

func iptablesPersist() {
	if _, err := exec.LookPath("netfilter-persistent"); err != nil {
		return
	}
	_, _ = runCmd(15*time.Second, "netfilter-persistent", "save")
}

func iptablesRun(spec shared.FirewallRuleSpec, allow bool) error {
	out, err := runCmd(30*time.Second, "iptables", iptablesArgs(spec, allow)...)
	if err != nil {
		return fmt.Errorf("iptables: %s", firstLine(out))
	}
	iptablesPersist()
	return nil
}

func iptablesDelete(id string) error {
	if _, err := strconv.Atoi(id); err != nil {
		return fmt.Errorf("bad iptables rule number %q", id)
	}
	out, err := runCmd(30*time.Second, "iptables", "-D", "INPUT", id)
	if err != nil {
		return fmt.Errorf("iptables delete: %s", firstLine(out))
	}
	iptablesPersist()
	return nil
}

// --- nftables (read-only) ------------------------------------------------------------------

func nftStatus(st *shared.FirewallStatus) error {
	st.Editable = false
	st.Note = "nftables without an iptables wrapper: listing only, rules are managed outside Beacle"
	out, err := runCmd(15*time.Second, "nft", "--json", "list", "ruleset")
	if err != nil {
		return fmt.Errorf("nft: %v", err)
	}
	var doc struct {
		Nftables []json.RawMessage `json:"nftables"`
	}
	if err := json.Unmarshal([]byte(out), &doc); err != nil {
		return fmt.Errorf("nft parse: %v", err)
	}
	type chainKey struct{ family, table, name string }
	inputChains := map[chainKey]string{}
	for _, raw := range doc.Nftables {
		var obj map[string]json.RawMessage
		if err := json.Unmarshal(raw, &obj); err != nil {
			continue
		}
		chainRaw, ok := obj["chain"]
		if !ok {
			continue
		}
		var ch struct {
			Family string `json:"family"`
			Table  string `json:"table"`
			Name   string `json:"name"`
			Hook   string `json:"hook"`
		}
		if json.Unmarshal(chainRaw, &ch) != nil || ch.Hook != "input" {
			continue
		}
		inputChains[chainKey{ch.Family, ch.Table, ch.Name}] = ch.Table + " " + ch.Name
	}
	if len(inputChains) == 0 {
		return nil
	}
	var names []string
	for _, n := range inputChains {
		names = append(names, n)
	}
	sort.Strings(names)
	st.BackendDetail = "input chains: " + strings.Join(names, ", ")
	st.Enabled = true
	for _, raw := range doc.Nftables {
		var obj map[string]json.RawMessage
		if err := json.Unmarshal(raw, &obj); err != nil {
			continue
		}
		ruleRaw, ok := obj["rule"]
		if !ok {
			continue
		}
		var header struct {
			Family string `json:"family"`
			Table  string `json:"table"`
			Chain  string `json:"chain"`
			Handle int    `json:"handle"`
		}
		if json.Unmarshal(ruleRaw, &header) != nil {
			continue
		}
		if _, ok := inputChains[chainKey{header.Family, header.Table, header.Chain}]; !ok {
			continue
		}
		st.Rules = append(st.Rules, parseNftRule(ruleRaw))
	}
	markProtectedRules(st)
	return nil
}

func nftStr(v any) string {
	switch t := v.(type) {
	case string:
		return t
	case float64:
		return strconv.Itoa(int(t))
	}
	return ""
}

func parseNftRule(ruleRaw json.RawMessage) shared.FirewallRule {
	r := shared.FirewallRule{Proto: "any", Action: "other", Raw: "complex rule"}
	var rule struct {
		Expr []map[string]any `json:"expr"`
	}
	if json.Unmarshal(ruleRaw, &rule) != nil {
		return r
	}
	var desc []string
	for _, e := range rule.Expr {
		if _, ok := e["accept"]; ok {
			r.Action = "allow"
			desc = append(desc, "accept")
			continue
		}
		if _, ok := e["drop"]; ok {
			r.Action = "deny"
			desc = append(desc, "drop")
			continue
		}
		if rej, ok := e["reject"]; ok {
			r.Action = "deny"
			_ = rej
			desc = append(desc, "reject")
			continue
		}
		m, ok := e["match"].(map[string]any)
		if !ok {
			continue
		}
		left, _ := m["left"].(map[string]any)
		payload, _ := left["payload"].(map[string]any)
		if payload == nil {
			continue
		}
		field, _ := payload["field"].(string)
		proto, _ := payload["protocol"].(string)
		switch field {
		case "dport":
			switch right := m["right"].(type) {
			case float64:
				r.Port = strconv.Itoa(int(right))
			case string:
				r.Port = right
			case map[string]any:
				if rng, ok := right["range"].([]any); ok && len(rng) == 2 {
					r.Port = nftStr(rng[0]) + ":" + nftStr(rng[1])
				}
			}
			if proto != "" {
				r.Proto = proto
			}
			desc = append(desc, proto+" dport "+r.Port)
		case "saddr":
			switch right := m["right"].(type) {
			case string:
				r.Source = right
			case map[string]any:
				if pfx, ok := right["prefix"].(map[string]any); ok {
					r.Source = fmt.Sprintf("%v/%v", pfx["addr"], pfx["len"])
				}
			}
			desc = append(desc, "from "+r.Source)
		}
	}
	if len(desc) > 0 {
		r.Raw = strings.Join(desc, " ")
	}
	return r
}

// --- mutations ------------------------------------------------------------------------

func shellJoin(argv []string) string {
	var b strings.Builder
	for i, a := range argv {
		if i > 0 {
			b.WriteString(" ")
		}
		if strings.ContainsAny(a, " \t\"'") {
			b.WriteString("'")
			b.WriteString(strings.ReplaceAll(a, "'", `'\''`))
			b.WriteString("'")
		} else {
			b.WriteString(a)
		}
	}
	return b.String()
}

func firstLine(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.Index(s, "\n"); i >= 0 {
		s = s[:i]
	}
	if s == "" {
		return "failed"
	}
	if len(s) > 200 {
		s = s[:200]
	}
	return s
}

func (c *linuxCollector) FirewallDryRun(req shared.FirewallDryRunRequest) (shared.FirewallDryRun, error) {
	var out shared.FirewallDryRun
	backend := detectFirewall()
	switch backend {
	case fwBackendNone, fwBackendNFT:
		return out, fmt.Errorf("backend %q is not editable", backend)
	}
	action := strings.ToLower(strings.TrimSpace(req.Action))
	if action == "delete" {
		id := strings.TrimSpace(req.ID)
		if id == "" {
			return out, fmt.Errorf("rule id is required")
		}
		cmd, warning, err := fwDeleteCommand(backend, id, c.protectedPorts())
		if err != nil {
			return out, err
		}
		out.Commands = []string{cmd}
		out.Warning = warning
		return out, nil
	}
	if req.Spec == nil {
		return out, fmt.Errorf("spec is required")
	}
	spec, err := validateFWSpec(*req.Spec)
	if err != nil {
		return out, err
	}
	allow := action == "allow"
	if action != "allow" && action != "deny" {
		return out, fmt.Errorf("action must be allow, deny or delete")
	}
	if !allow {
		warning, err := guardDeny(spec, c.protectedPorts())
		if err != nil {
			return out, err
		}
		out.Warning = warning
	}
	switch backend {
	case fwBackendUFW:
		verb := "deny"
		if allow {
			verb = "allow"
		}
		out.Commands = ufwCommands(verb, spec)
	case fwBackendFirewalld:
		zone := firewalldZone()
		if spec.Port != "" && spec.Source == "" && allow {
			lo, hi, _, _ := parseFWPort(spec.Port)
			port := strconv.Itoa(lo)
			if hi != lo {
				port = fmt.Sprintf("%d-%d", lo, hi)
			}
			out.Commands = []string{
				shellJoin([]string{"firewall-cmd", "--permanent", "--zone=" + zone, "--add-port=" + port + "/" + spec.Proto}),
				"firewall-cmd --reload",
			}
		} else {
			out.Commands = []string{
				shellJoin([]string{"firewall-cmd", "--permanent", "--zone=" + zone, "--add-rich-rule=" + fwRichRule(spec, allow)}),
				"firewall-cmd --reload",
			}
		}
	case fwBackendIptables:
		out.Commands = []string{shellJoin(append([]string{"iptables"}, iptablesArgs(spec, allow)...))}
	}
	return out, nil
}

// fwDeleteCommand resolves a rule ID to its native delete command, enforcing
// the guard. Callers holding fwMu must already hold it — this re-lists state,
// so apply paths resolve-then-delete under the same lock.
func fwDeleteCommand(backend, id string, protected []int) (string, string, error) {
	zone := ""
	if backend == fwBackendFirewalld {
		zone = firewalldZone()
	}
	// Find the rule to enforce the protected-allow guard.
	var st shared.FirewallStatus
	st.ProtectedPorts = protected
	st.Backend = backend
	var err error
	switch backend {
	case fwBackendUFW:
		err = ufwStatus(&st)
	case fwBackendFirewalld:
		err = firewalldStatus(&st)
	case fwBackendIptables:
		err = iptablesStatus(&st)
	default:
		return "", "", fmt.Errorf("backend %q is not editable", backend)
	}
	if err != nil {
		return "", "", err
	}
	var found *shared.FirewallRule
	for i := range st.Rules {
		if st.Rules[i].ID == id {
			found = &st.Rules[i]
			break
		}
	}
	if found == nil || found.ID == "" {
		return "", "", fmt.Errorf("rule %q no longer exists — reload and retry", id)
	}
	warning := ""
	if found.Protected {
		warning = fmt.Sprintf("allows protected port %s — deleting may cut off SSH", found.Port)
	}
	switch backend {
	case fwBackendUFW:
		return shellJoin([]string{"ufw", "--force", "delete", id}), warning, nil
	case fwBackendFirewalld:
		op, err := firewalldDelete(zone, id)
		if err != nil {
			return "", "", err
		}
		return shellJoin([]string{"firewall-cmd", "--permanent", "--zone=" + zone, op}) + " && firewall-cmd --reload", warning, nil
	case fwBackendIptables:
		return shellJoin([]string{"iptables", "-D", "INPUT", id}), warning, nil
	}
	return "", "", fmt.Errorf("unreachable")
}

func (c *linuxCollector) FirewallAllow(spec shared.FirewallRuleSpec) (shared.FirewallMutation, error) {
	var res shared.FirewallMutation
	spec, err := validateFWSpec(spec)
	if err != nil {
		return res, err
	}
	if spec.Action != "allow" {
		return res, fmt.Errorf("action must be allow")
	}
	if spec.Port == "" {
		return res, fmt.Errorf("refusing allow-all: set a port or a source")
	}
	fwMu.Lock()
	defer fwMu.Unlock()
	switch detectFirewall() {
	case fwBackendUFW:
		err = ufwRun(spec, true)
	case fwBackendFirewalld:
		err = firewalldRun(spec, true)
	case fwBackendIptables:
		err = iptablesRun(spec, true)
	default:
		err = fmt.Errorf("no editable firewall backend")
	}
	if err != nil {
		return res, err
	}
	res.OK = true
	return res, nil
}

func (c *linuxCollector) FirewallDeny(spec shared.FirewallRuleSpec) (shared.FirewallMutation, error) {
	var res shared.FirewallMutation
	spec, err := validateFWSpec(spec)
	if err != nil {
		return res, err
	}
	if spec.Action != "deny" {
		return res, fmt.Errorf("action must be deny")
	}
	warning, err := guardDeny(spec, c.protectedPorts())
	if err != nil {
		return res, err
	}
	fwMu.Lock()
	defer fwMu.Unlock()
	switch detectFirewall() {
	case fwBackendUFW:
		err = ufwRun(spec, false)
	case fwBackendFirewalld:
		err = firewalldRun(spec, false)
	case fwBackendIptables:
		err = iptablesRun(spec, false)
	default:
		err = fmt.Errorf("no editable firewall backend")
	}
	if err != nil {
		return res, err
	}
	res.OK = true
	res.Warning = warning
	return res, nil
}

func (c *linuxCollector) FirewallDelete(req shared.FirewallDeleteRequest) (shared.FirewallMutation, error) {
	var res shared.FirewallMutation
	backend := detectFirewall()
	switch backend {
	case fwBackendNone, fwBackendNFT:
		return res, fmt.Errorf("backend %q is not editable", backend)
	}
	fwMu.Lock()
	defer fwMu.Unlock()
	_, warning, err := fwDeleteCommand(backend, strings.TrimSpace(req.ID), c.protectedPorts())
	if err != nil {
		return res, err
	}
	if warning != "" && !req.Force {
		return res, fmt.Errorf("%s — confirm explicitly to proceed", warning)
	}
	switch backend {
	case fwBackendUFW:
		err = ufwDelete(req.ID)
	case fwBackendFirewalld:
		var op string
		op, err = firewalldDelete(firewalldZone(), req.ID)
		if err == nil {
			_, err = runCmd(30*time.Second, "firewall-cmd",
				"--permanent", "--zone="+firewalldZone(), op)
			if err == nil {
				_, err = runCmd(30*time.Second, "firewall-cmd", "--reload")
			}
		}
		if err != nil {
			err = fmt.Errorf("firewall-cmd: %v", err)
		}
	case fwBackendIptables:
		err = iptablesDelete(req.ID)
	}
	if err != nil {
		return res, err
	}
	res.OK = true
	res.Warning = warning
	return res, nil
}
