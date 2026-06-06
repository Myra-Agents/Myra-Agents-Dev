// myra-tui — Bubble Tea renderer for the Myra bootstrap scripts.
//
// It does no work itself: bootstrap.sh runs the real steps and writes a stream
// of newline-delimited *events* to its stdout, which is piped into this program.
// Each event line is prefixed with the sentinel "\x1fMYRA\x1f" followed by
// tab-separated fields; any other line is treated as raw log output (git/bun
// chatter) and shown as a dim scrolling tail.
//
// Crucially, events arrive on os.Stdin (the pipe) while the live display and key
// input use /dev/tty — so the program still renders correctly under
// `curl ... | bash` where the script's own stdout is not a terminal. If /dev/tty
// cannot be opened the caller is expected to fall back to plain mode; we also
// bail out defensively here.
package main

import (
	"bufio"
	"fmt"
	"os"
	"regexp"
	"strings"

	"github.com/charmbracelet/bubbles/spinner"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

const sentinel = "\x1fMYRA\x1f"

// ── styles ─────────────────────────────────────────────────────────────────
var (
	cGreen  = lipgloss.NewStyle().Foreground(lipgloss.Color("2"))
	cYellow = lipgloss.NewStyle().Foreground(lipgloss.Color("3"))
	cRed    = lipgloss.NewStyle().Foreground(lipgloss.Color("1"))
	cDim    = lipgloss.NewStyle().Faint(true)
	cBold   = lipgloss.NewStyle().Bold(true)
)

var ansiRE = regexp.MustCompile(`\x1b\[[0-9;]*[a-zA-Z]`)

// ── model ──────────────────────────────────────────────────────────────────
type stepState int

const (
	pending stepState = iota
	running
	stOK
	stWarn
	stFail
	stSkip
)

type step struct {
	id, title, note string
	state           stepState
}

type group struct {
	id, title string
	steps     []*step
}

type model struct {
	title   string
	groups  []*group
	logs    []string // ring buffer of the last few raw log lines
	maxLogs int
	sp      spinner.Model
	done    bool
	doneMsg string
	fatal   string
	width   int
}

// ── stream messages ─────────────────────────────────────────────────────────
type eventMsg []string // kind + fields
type logMsg string
type eofMsg struct{}

// readStream pumps the pipe (os.Stdin) into the Bubble Tea program.
func readStream(p *tea.Program) {
	sc := bufio.NewScanner(os.Stdin)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		line := sc.Text()
		if strings.HasPrefix(line, sentinel) {
			p.Send(eventMsg(strings.Split(strings.TrimPrefix(line, sentinel), "\t")))
		} else {
			p.Send(logMsg(line))
		}
	}
	p.Send(eofMsg{})
}

func (m model) Init() tea.Cmd { return m.sp.Tick }

func (m *model) findStep(id string) *step {
	for _, g := range m.groups {
		for _, s := range g.steps {
			if s.id == id {
				return s
			}
		}
	}
	return nil
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		// Ctrl-C / q aborts the view; the underlying bash keeps running but the
		// user gets their terminal back. Rare; mostly a safety valve.
		switch msg.String() {
		case "ctrl+c", "q":
			return m, tea.Quit
		}

	case spinner.TickMsg:
		var cmd tea.Cmd
		m.sp, cmd = m.sp.Update(msg)
		return m, cmd

	case eventMsg:
		m.applyEvent([]string(msg))
		return m, nil

	case logMsg:
		s := strings.TrimRight(ansiRE.ReplaceAllString(string(msg), ""), " \t")
		if strings.TrimSpace(s) != "" {
			m.logs = append(m.logs, s)
			if len(m.logs) > m.maxLogs {
				m.logs = m.logs[len(m.logs)-m.maxLogs:]
			}
		}
		return m, nil

	case eofMsg:
		return m, tea.Quit

	case tea.WindowSizeMsg:
		m.width = msg.Width
		return m, nil
	}
	return m, nil
}

func (m *model) applyEvent(f []string) {
	if len(f) == 0 {
		return
	}
	kind := f[0]
	arg := func(i int) string {
		if i < len(f) {
			return f[i]
		}
		return ""
	}
	switch kind {
	case "title":
		m.title = arg(1)
	case "group":
		m.groups = append(m.groups, &group{id: arg(1), title: arg(2)})
	case "step":
		if len(m.groups) == 0 {
			m.groups = append(m.groups, &group{id: "_", title: ""})
		}
		g := m.groups[len(m.groups)-1]
		g.steps = append(g.steps, &step{id: arg(1), title: arg(2), state: running})
	case "state":
		if s := m.findStep(arg(1)); s != nil {
			s.state = parseState(arg(2))
		}
	case "note":
		if s := m.findStep(arg(1)); s != nil {
			s.note = arg(2)
		}
	case "done":
		m.done = true
		m.doneMsg = arg(1)
	case "fatal":
		m.fatal = arg(1)
	}
}

func parseState(s string) stepState {
	switch s {
	case "run":
		return running
	case "ok":
		return stOK
	case "warn":
		return stWarn
	case "fail":
		return stFail
	case "skip":
		return stSkip
	default:
		return pending
	}
}

func (m model) icon(s stepState) string {
	switch s {
	case running:
		return m.sp.View()
	case stOK:
		return cGreen.Render("✓")
	case stWarn:
		return cYellow.Render("!")
	case stFail:
		return cRed.Render("✗")
	case stSkip:
		return cYellow.Render("○")
	default:
		return cDim.Render("○")
	}
}

func (m model) View() string {
	var b strings.Builder
	if m.title != "" {
		b.WriteString(cGreen.Render(cBold.Render(m.title)) + "\n\n")
	}
	for _, g := range m.groups {
		if g.title != "" {
			b.WriteString(cBold.Render(g.title) + "\n")
		}
		for _, s := range g.steps {
			line := fmt.Sprintf("  %s %s", m.icon(s.state), s.title)
			if s.note != "" {
				line += " " + cDim.Render(s.note)
			}
			b.WriteString(line + "\n")
		}
	}
	// scrolling raw-log tail under an active run
	if !m.done && len(m.logs) > 0 {
		b.WriteString("\n")
		for _, l := range m.logs {
			b.WriteString(cDim.Render("  "+truncate(l, m.width-4)) + "\n")
		}
	}
	if m.fatal != "" {
		b.WriteString("\n" + cRed.Render("✗ "+m.fatal) + "\n")
	}
	if m.done && m.doneMsg != "" {
		b.WriteString("\n" + cGreen.Render(m.doneMsg) + "\n")
	}
	return b.String()
}

func truncate(s string, w int) string {
	if w <= 1 || len(s) <= w {
		return s
	}
	if w < 2 {
		return s[:w]
	}
	return s[:w-1] + "…"
}

func main() {
	// The display + key input go to the real terminal even though events arrive
	// on the piped stdin. If we can't open it, plain mode is the caller's job —
	// exit non-zero so a `|| fallback` in bash can react, but harmlessly.
	tty, err := os.OpenFile("/dev/tty", os.O_RDWR, 0)
	if err != nil {
		fmt.Fprintln(os.Stderr, "myra-tui: no /dev/tty:", err)
		os.Exit(2)
	}
	defer tty.Close()

	sp := spinner.New()
	sp.Spinner = spinner.Dot
	sp.Style = cGreen

	m := model{sp: sp, maxLogs: 6, width: 80}
	p := tea.NewProgram(m, tea.WithInput(tty), tea.WithOutput(tty))

	go readStream(p)

	if _, err := p.Run(); err != nil {
		fmt.Fprintln(os.Stderr, "myra-tui:", err)
		os.Exit(1)
	}
}
