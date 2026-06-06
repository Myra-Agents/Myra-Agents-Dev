package main

import (
	"strings"
	"testing"

	"github.com/charmbracelet/bubbles/spinner"
)

func newModel() model {
	sp := spinner.New()
	return model{sp: sp, maxLogs: 6, width: 80}
}

// feed parses a sentinel-prefixed event line the way readStream would and applies it.
func (m *model) feed(line string) {
	if !strings.HasPrefix(line, sentinel) {
		m.logs = append(m.logs, line)
		return
	}
	m.applyEvent(strings.Split(strings.TrimPrefix(line, sentinel), "\t"))
}

func TestEventStreamBuildsTree(t *testing.T) {
	m := newModel()
	m.feed(sentinel + "title\tMyra")
	m.feed(sentinel + "group\ttools\tToolchain")
	m.feed(sentinel + "step\ts1\tbun")
	m.feed(sentinel + "note\ts1\t1.3.0")
	m.feed(sentinel + "state\ts1\tok")
	m.feed(sentinel + "step\ts2\tgh")
	m.feed(sentinel + "state\ts2\tfail")

	if m.title != "Myra" {
		t.Fatalf("title = %q", m.title)
	}
	if len(m.groups) != 1 || len(m.groups[0].steps) != 2 {
		t.Fatalf("group/step shape wrong: %+v", m.groups)
	}
	if s := m.findStep("s1"); s == nil || s.state != stOK || s.note != "1.3.0" {
		t.Fatalf("s1 = %+v", s)
	}
	if s := m.findStep("s2"); s == nil || s.state != stFail {
		t.Fatalf("s2 = %+v", s)
	}
}

func TestStepWithoutGroupGetsImplicitGroup(t *testing.T) {
	m := newModel()
	m.feed(sentinel + "step\ts1\tlonely")
	if len(m.groups) != 1 || len(m.groups[0].steps) != 1 {
		t.Fatalf("expected implicit group, got %+v", m.groups)
	}
}

func TestRawLogTailRingBuffer(t *testing.T) {
	m := newModel()
	// drive through the same path Update(logMsg) uses
	for i := 0; i < 20; i++ {
		s := ansiRE.ReplaceAllString("\x1b[32mline\x1b[0m", "")
		m.logs = append(m.logs, s)
		if len(m.logs) > m.maxLogs {
			m.logs = m.logs[len(m.logs)-m.maxLogs:]
		}
	}
	if len(m.logs) != m.maxLogs {
		t.Fatalf("ring buffer len = %d, want %d", len(m.logs), m.maxLogs)
	}
	if strings.Contains(m.logs[0], "\x1b") {
		t.Fatalf("ANSI not stripped: %q", m.logs[0])
	}
}

func TestFatalAndDoneRender(t *testing.T) {
	m := newModel()
	m.feed(sentinel + "group\tg\tG")
	m.feed(sentinel + "step\ts1\twork")
	m.feed(sentinel + "state\ts1\tfail")
	m.feed(sentinel + "fatal\tboom")
	out := m.View()
	if !strings.Contains(out, "boom") {
		t.Fatalf("fatal not rendered:\n%s", out)
	}

	m2 := newModel()
	m2.done = true
	m2.doneMsg = "✓ Workspace ready"
	if !strings.Contains(m2.View(), "Workspace ready") {
		t.Fatalf("done not rendered")
	}
}

func TestParseState(t *testing.T) {
	cases := map[string]stepState{
		"run": running, "ok": stOK, "warn": stWarn,
		"fail": stFail, "skip": stSkip, "???": pending,
	}
	for in, want := range cases {
		if got := parseState(in); got != want {
			t.Errorf("parseState(%q) = %v, want %v", in, got, want)
		}
	}
}

func TestTruncate(t *testing.T) {
	if got := truncate("hello world", 5); got != "hell…" {
		t.Errorf("truncate = %q", got)
	}
	if got := truncate("hi", 10); got != "hi" {
		t.Errorf("truncate short = %q", got)
	}
}
