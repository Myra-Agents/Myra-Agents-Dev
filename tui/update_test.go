package main

import (
	"io"
	"os"
	"strings"
	"testing"

	"github.com/charmbracelet/bubbles/spinner"
	tea "github.com/charmbracelet/bubbletea"
)

// isQuitCmd reports whether running cmd yields a tea.QuitMsg — the signal the
// model uses to hand the terminal back to bash.
func isQuitCmd(cmd tea.Cmd) bool {
	if cmd == nil {
		return false
	}
	_, ok := cmd().(tea.QuitMsg)
	return ok
}

// updated is a tiny helper that drives one Update and returns the concrete model
// plus the command, so tests read like a script of messages.
func updated(m model, msg tea.Msg) (model, tea.Cmd) {
	tm, cmd := m.Update(msg)
	return tm.(model), cmd
}

// ── Init ─────────────────────────────────────────────────────────────────────

func TestInitReturnsSpinnerTick(t *testing.T) {
	m := initialModel()
	cmd := m.Init()
	if cmd == nil {
		t.Fatal("Init() returned nil cmd; expected the spinner tick")
	}
	// The tick command must produce a spinner.TickMsg so the dot keeps spinning.
	if _, ok := cmd().(spinner.TickMsg); !ok {
		t.Fatalf("Init() cmd did not yield spinner.TickMsg, got %T", cmd())
	}
}

// ── initialModel defaults ────────────────────────────────────────────────────

func TestInitialModelDefaults(t *testing.T) {
	m := initialModel()
	if m.maxLogs != 6 {
		t.Errorf("maxLogs = %d, want 6", m.maxLogs)
	}
	if m.width != 80 {
		t.Errorf("width = %d, want 80", m.width)
	}
	if m.done || m.fatal != "" || len(m.groups) != 0 || len(m.logs) != 0 {
		t.Errorf("fresh model not zeroed: %+v", m)
	}
}

// ── Update: keys ─────────────────────────────────────────────────────────────

func TestUpdateQuitKeys(t *testing.T) {
	for _, key := range []string{"ctrl+c", "q"} {
		m := initialModel()
		_, cmd := updated(m, tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(key)})
		if key == "ctrl+c" {
			// ctrl+c is a control key, not runes — build it explicitly.
			_, cmd = updated(m, tea.KeyMsg{Type: tea.KeyCtrlC})
		}
		if !isQuitCmd(cmd) {
			t.Errorf("key %q did not quit", key)
		}
	}
}

func TestUpdateUnhandledKeyIsNoop(t *testing.T) {
	m := initialModel()
	_, cmd := updated(m, tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("x")})
	if isQuitCmd(cmd) {
		t.Fatal("unrelated key should not quit")
	}
}

// ── Update: spinner tick ─────────────────────────────────────────────────────

func TestUpdateSpinnerTickReschedules(t *testing.T) {
	m := initialModel()
	// Feed the spinner its own tick; it should return a follow-up tick command so
	// the animation continues.
	_, cmd := updated(m, m.sp.Tick())
	if cmd == nil {
		t.Fatal("spinner tick produced no follow-up command")
	}
}

// ── Update: events ───────────────────────────────────────────────────────────

func TestUpdateEventMsgAppliesState(t *testing.T) {
	m := initialModel()
	m, _ = updated(m, eventMsg{"group", "g", "Group"})
	m, _ = updated(m, eventMsg{"step", "s1", "work"})
	m, _ = updated(m, eventMsg{"state", "s1", "ok"})
	if s := m.findStep("s1"); s == nil || s.state != stOK {
		t.Fatalf("event path did not mark s1 ok: %+v", s)
	}
}

// ── Update: logs ─────────────────────────────────────────────────────────────

func TestUpdateLogMsgStripsANSIAndRings(t *testing.T) {
	m := initialModel()
	for i := 0; i < 20; i++ {
		m, _ = updated(m, logMsg("\x1b[32mcloning\x1b[0m   "))
	}
	if len(m.logs) != m.maxLogs {
		t.Fatalf("ring buffer len = %d, want %d", len(m.logs), m.maxLogs)
	}
	for _, l := range m.logs {
		if strings.Contains(l, "\x1b") {
			t.Fatalf("ANSI not stripped: %q", l)
		}
		if strings.HasSuffix(l, " ") || strings.HasSuffix(l, "\t") {
			t.Fatalf("trailing whitespace not trimmed: %q", l)
		}
	}
}

func TestUpdateBlankLogIgnored(t *testing.T) {
	m := initialModel()
	m, _ = updated(m, logMsg("   \t  "))
	m, _ = updated(m, logMsg("\x1b[0m"))
	if len(m.logs) != 0 {
		t.Fatalf("blank/ANSI-only lines should be dropped, got %v", m.logs)
	}
}

// ── Update: EOF + window size ────────────────────────────────────────────────

func TestUpdateEOFQuits(t *testing.T) {
	m := initialModel()
	_, cmd := updated(m, eofMsg{})
	if !isQuitCmd(cmd) {
		t.Fatal("eofMsg should quit")
	}
}

func TestUpdateWindowSizeSetsWidth(t *testing.T) {
	m := initialModel()
	m, _ = updated(m, tea.WindowSizeMsg{Width: 120, Height: 40})
	if m.width != 120 {
		t.Fatalf("width = %d, want 120", m.width)
	}
}

func TestUpdateUnknownMsgIsNoop(t *testing.T) {
	m := initialModel()
	type weird struct{}
	out, cmd := updated(m, weird{})
	if cmd != nil {
		t.Fatal("unknown msg should yield nil cmd")
	}
	if out.width != m.width {
		t.Fatal("unknown msg mutated model")
	}
}

// ── icon: every state ────────────────────────────────────────────────────────

func TestIconForEveryState(t *testing.T) {
	m := initialModel()
	cases := []struct {
		state stepState
		glyph string
	}{
		{stOK, "✓"},
		{stWarn, "!"},
		{stFail, "✗"},
		{stSkip, "○"},
		{pending, "○"},
	}
	for _, c := range cases {
		if got := m.icon(c.state); !strings.Contains(got, c.glyph) {
			t.Errorf("icon(%v) = %q, want to contain %q", c.state, got, c.glyph)
		}
	}
	// running renders the live spinner frame — just assert it is non-empty.
	if got := m.icon(running); strings.TrimSpace(got) == "" {
		t.Error("icon(running) should render a spinner frame")
	}
}

// ── findStep miss ────────────────────────────────────────────────────────────

func TestFindStepMiss(t *testing.T) {
	m := initialModel()
	m, _ = updated(m, eventMsg{"group", "g", "G"})
	m, _ = updated(m, eventMsg{"step", "s1", "x"})
	if got := m.findStep("nope"); got != nil {
		t.Fatalf("findStep(nope) = %+v, want nil", got)
	}
	// state/note for an unknown id must be a safe no-op (exercises the nil branch).
	m.applyEvent([]string{"state", "ghost", "ok"})
	m.applyEvent([]string{"note", "ghost", "hi"})
}

// ── applyEvent edges ─────────────────────────────────────────────────────────

func TestApplyEventEmptyAndDone(t *testing.T) {
	m := initialModel()
	m.applyEvent(nil)        // len 0 → no panic, no-op
	m.applyEvent([]string{}) // same
	m.applyEvent([]string{"done", "✓ Workspace ready"})
	if !m.done || m.doneMsg != "✓ Workspace ready" {
		t.Fatalf("done event not applied: done=%v msg=%q", m.done, m.doneMsg)
	}
	// title set, group/step missing trailing args use the empty-arg fallback.
	m.applyEvent([]string{"title"})
	m.applyEvent([]string{"unknown-kind"}) // default branch: ignored
}

// ── View: log tail under an active run ───────────────────────────────────────

func TestViewRendersLogTailWhileRunning(t *testing.T) {
	m := initialModel()
	m.width = 12 // force truncation through the View → truncate path
	m, _ = updated(m, eventMsg{"title", "Myra Agents"})
	m, _ = updated(m, eventMsg{"group", "g", "Toolchain"})
	m, _ = updated(m, eventMsg{"step", "s1", "cloning a very long step title that overflows"})
	m, _ = updated(m, eventMsg{"note", "s1", "v1.3.0"}) // exercises the note render branch
	m, _ = updated(m, logMsg("a fairly long raw git log line that must be truncated"))
	out := m.View()
	if !strings.Contains(out, "Myra Agents") {
		t.Error("title missing from View")
	}
	if !strings.Contains(out, "v1.3.0") {
		t.Error("step note missing from View")
	}
	if !strings.Contains(out, "…") {
		t.Error("expected an ellipsis from truncation in the log tail")
	}
	// Once done, the log tail is suppressed.
	m.done = true
	if strings.Contains(m.View(), "…") {
		t.Error("log tail should be hidden when done")
	}
}

// ── readStream: the real pipe→program pump ───────────────────────────────────

// TestReadStreamPumpsPipe wires a pipe to os.Stdin and runs the exact
// production goroutine pattern (go readStream(p); p.Run()). It asserts that
// events build the tree, raw lines land in the log ring, and EOF quits — all
// without a TTY, via WithoutRenderer.
func TestReadStreamPumpsPipe(t *testing.T) {
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("pipe: %v", err)
	}
	oldStdin := os.Stdin
	os.Stdin = r
	defer func() { os.Stdin = oldStdin }()

	p := tea.NewProgram(
		initialModel(),
		tea.WithInput(strings.NewReader("")),
		tea.WithOutput(io.Discard),
		tea.WithoutRenderer(),
	)

	go readStream(p)
	go func() {
		io.WriteString(w, sentinel+"title\tMyra\n")
		io.WriteString(w, sentinel+"group\tg\tToolchain\n")
		io.WriteString(w, sentinel+"step\ts1\tbun\n")
		io.WriteString(w, sentinel+"state\ts1\tok\n")
		io.WriteString(w, "raw cloning chatter\n")
		w.Close() // EOF → readStream sends eofMsg → program quits
	}()

	out, err := p.Run()
	if err != nil {
		t.Fatalf("program run: %v", err)
	}
	fm := out.(model)
	if fm.title != "Myra" {
		t.Errorf("title = %q, want Myra", fm.title)
	}
	if s := fm.findStep("s1"); s == nil || s.state != stOK {
		t.Errorf("s1 not ok after stream: %+v", s)
	}
	found := false
	for _, l := range fm.logs {
		if strings.Contains(l, "raw cloning chatter") {
			found = true
		}
	}
	if !found {
		t.Errorf("raw log line not captured, logs = %v", fm.logs)
	}
}
