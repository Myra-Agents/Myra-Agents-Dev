// prompts.go — huh-backed interactive subcommands for myra-tui.
//
// The shell scripts shell out to these (via ui.sh's ui_confirm/ui_input/
// ui_select) when a TUI is available, and fall back to plain /dev/tty reads
// otherwise. The form always draws on /dev/tty — never stdin/stdout — so it
// works under `curl … | bash`, where the caller's stdin is the download pipe.
// Any captured result is printed to real stdout for $(command) substitution.
//
// Exit codes are the contract with the shell:
//
//	0  confirmed / value returned
//	1  declined or user-aborted (Esc/Ctrl-C)
//	2  no /dev/tty, or bad usage — caller should fall back to a plain prompt
package main

import (
	"fmt"
	"os"

	"github.com/charmbracelet/huh"
)

func runPrompt(kind string, args []string) int {
	tty, err := os.OpenFile("/dev/tty", os.O_RDWR, 0)
	if err != nil {
		fmt.Fprintln(os.Stderr, "myra-tui: no /dev/tty:", err)
		return 2
	}
	defer tty.Close()

	run := func(f *huh.Form) error {
		return f.WithInput(tty).WithOutput(tty).Run()
	}

	switch kind {
	case "confirm":
		title, def := parseFlagArgs(args)
		val := def == "yes" || def == "y" || def == "true"
		f := huh.NewForm(huh.NewGroup(
			huh.NewConfirm().Title(title).Affirmative("Yes").Negative("No").Value(&val),
		))
		if err := run(f); err != nil {
			return 1
		}
		if val {
			return 0
		}
		return 1

	case "input":
		title, def := parseFlagArgs(args)
		val := def
		f := huh.NewForm(huh.NewGroup(
			huh.NewInput().Title(title).Value(&val),
		))
		if err := run(f); err != nil {
			return 1
		}
		fmt.Println(val)
		return 0

	case "select":
		if len(args) < 2 {
			fmt.Fprintln(os.Stderr, "myra-tui select: need a title and at least one option")
			return 2
		}
		title, opts := args[0], args[1:]
		var val string
		hopts := make([]huh.Option[string], len(opts))
		for i, o := range opts {
			hopts[i] = huh.NewOption(o, o)
		}
		f := huh.NewForm(huh.NewGroup(
			huh.NewSelect[string]().Title(title).Options(hopts...).Value(&val),
		))
		if err := run(f); err != nil {
			return 1
		}
		fmt.Println(val)
		return 0
	}
	return 2
}

// parseFlagArgs pulls the first positional arg as the title and an optional
// "--default <value>" pair. Used by confirm (yes/no) and input (free text).
func parseFlagArgs(args []string) (title, def string) {
	for i := 0; i < len(args); i++ {
		if args[i] == "--default" && i+1 < len(args) {
			def = args[i+1]
			i++
			continue
		}
		if title == "" {
			title = args[i]
		}
	}
	return
}
