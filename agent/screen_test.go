//go:build linux || windows || darwin

package main

import (
	"strings"
	"testing"
)

func TestScreenNameRejectsShellMetacharacters(t *testing.T) {
	// The name is passed to `screen -S`; anything that could become a separate
	// argument or a shell escape has to be refused at this boundary.
	bad := []string{
		"", "bot;rm -rf /", "bot name", "bot$(id)", "bot`id`", "bot|cat", "../bot",
		"bot\nname", "bot&", "-dmS",
	}
	for _, name := range bad {
		if _, err := screenName(name); err == nil {
			t.Errorf("screenName(%q) accepted a name it should reject", name)
		}
	}

	good := []string{"bot", "bot-python", "bot_2", "minecraft.survival", "A1"}
	for _, name := range good {
		if _, err := screenName(name); err != nil {
			t.Errorf("screenName(%q) rejected a valid name: %v", name, err)
		}
	}
}

func TestScreenNameLengthCap(t *testing.T) {
	long := make([]byte, 65)
	for i := range long {
		long[i] = 'a'
	}
	if _, err := screenName(string(long)); err == nil {
		t.Error("a 65 character session name should be rejected")
	}
}

func TestScreenLinesAreSeparateCommands(t *testing.T) {
	// Chaining with && meant a failed cd swallowed the command, and the whole
	// thing arrived as one line — so `python 3 agent.py` ran in the wrong
	// directory instead of failing on its own line.
	got := screenLines("/home/ubuntu/bot", "python3 main.py")
	want := []string{"cd '/home/ubuntu/bot'", "python3 main.py"}
	if len(got) != len(want) {
		t.Fatalf("got %d lines %q, want %d", len(got), got, len(want))
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("line %d = %q, want %q", i, got[i], want[i])
		}
	}
	for _, line := range got {
		if strings.Contains(line, "&&") {
			t.Errorf("lines must stay independent, got %q", line)
		}
	}
}

func TestScreenLinesSkipCdWhenDirectoryIsDefault(t *testing.T) {
	// Empty means "wherever the session opens" — emitting `cd ''` would send
	// the shell somewhere unexpected.
	got := screenLines("", "python3 bot.py")
	if len(got) != 1 || got[0] != "python3 bot.py" {
		t.Errorf("got %q, want just the command", got)
	}
}

func TestScreenLinesQuoteAwkwardDirectories(t *testing.T) {
	got := screenLines("/home/o'brien/my bot", "ls")
	if got[0] != `cd '/home/o'\''brien/my bot'` {
		t.Errorf("cd line = %q", got[0])
	}
}

func TestShellQuoteContainsSingleQuotes(t *testing.T) {
	cases := map[string]string{
		"/home/ubuntu/bot":     `'/home/ubuntu/bot'`,
		"/home/o'brien/bot":    `'/home/o'\''brien/bot'`,
		"/tmp/a b":             `'/tmp/a b'`,
		"'; rm -rf / ; echo '": `''\''; rm -rf / ; echo '\'''`,
	}
	for in, want := range cases {
		if got := shellQuote(in); got != want {
			t.Errorf("shellQuote(%q) = %q, want %q", in, got, want)
		}
	}
}
