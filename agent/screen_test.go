//go:build linux || windows || darwin

package main

import "testing"

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
