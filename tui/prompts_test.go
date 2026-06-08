package main

import "testing"

func TestParseFlagArgs(t *testing.T) {
	cases := []struct {
		name      string
		args      []string
		wantTitle string
		wantDef   string
	}{
		{"title only", []string{"Continue?"}, "Continue?", ""},
		{"title + default", []string{"Continue?", "--default", "yes"}, "Continue?", "yes"},
		{"default before extra positional ignored", []string{"Pick", "--default", "x", "stray"}, "Pick", "x"},
		{"dangling --default keeps title", []string{"Q", "--default"}, "Q", ""},
		{"empty", nil, "", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			gotTitle, gotDef := parseFlagArgs(c.args)
			if gotTitle != c.wantTitle || gotDef != c.wantDef {
				t.Fatalf("parseFlagArgs(%v) = (%q,%q), want (%q,%q)",
					c.args, gotTitle, gotDef, c.wantTitle, c.wantDef)
			}
		})
	}
}

// runPrompt with an unknown kind must signal "fall back to plain" (exit 2),
// not crash. (The tty-driven paths can't run headless, so we cover the guard.)
func TestRunPromptUnknownKind(t *testing.T) {
	if code := runPrompt("nope", nil); code != 2 {
		t.Fatalf("unknown kind exit = %d, want 2", code)
	}
}
