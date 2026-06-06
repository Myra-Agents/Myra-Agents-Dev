# shellcheck shell=bash
# ui.sh — progress reporting shared by the bootstrap scripts.
#
# Every step is reported through step_begin/step_end (+ ui_group/ui_title/ui_done).
# Those helpers emit one of two things depending on $TUI:
#   TUI=1 → newline-delimited *events* (sentinel-prefixed) for tui/myra-tui to render
#   TUI=0 → the same plain, colored output the scripts always had
# so a missing Go toolchain or a pipe with no /dev/tty silently degrades — never fatal.
#
# Targets macOS bash 3.2: no associative arrays, no `local x=$1 y=$x` in one stmt.

SENT=$'\037MYRA\037'           # \x1f sentinel — must match tui/main.go
TAB=$'\t'

# colors (plain mode only; events carry no color)
c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_red=$'\033[31m'; c_dim=$'\033[2m'; c_rst=$'\033[0m'

: "${TUI:=0}"
CUR_STEP=""; CUR_TITLE=""; _sid=0

# ev <kind> [field...] — emit one tab-separated event record.
ev() {
  local k="$1"; shift
  local rest=""
  local x
  for x in "$@"; do rest="$rest$TAB$x"; done
  printf '%s%s%s\n' "$SENT" "$k" "$rest"
}

ui_title() {
  if [ "$TUI" = 1 ]; then ev title "$1"; else echo "${c_grn}$1${c_rst}"; fi
}

ui_group() {  # <id> <title>
  if [ "$TUI" = 1 ]; then ev group "$1" "$2"; else echo; echo "${c_grn}▶${c_rst} $2"; fi
}

ui_done() {   # <summary line>
  if [ "$TUI" = 1 ]; then ev done "$1"; fi   # plain mode prints its own summary
}

# step_begin <title> — start a step (spinner in TUI; nothing in plain).
step_begin() {
  _sid=$((_sid + 1))
  CUR_STEP="s$_sid"
  CUR_TITLE="$1"
  [ "$TUI" = 1 ] && ev step "$CUR_STEP" "$1"
  return 0
}

# step_end <ok|warn|fail|skip> [note] — resolve the most recent step.
step_end() {
  local st="$1"
  local note="${2:-}"
  if [ "$TUI" = 1 ]; then
    [ -n "$note" ] && ev note "$CUR_STEP" "$note"
    ev state "$CUR_STEP" "$st"
  else
    local ic
    case "$st" in
      ok)   ic="${c_grn}✓${c_rst}" ;;
      warn) ic="${c_yel}!${c_rst}" ;;
      fail) ic="${c_red}✗${c_rst}" ;;
      skip) ic="${c_yel}○${c_rst}" ;;
      *)    ic="${c_dim}○${c_rst}" ;;
    esac
    if [ -n "$note" ]; then
      printf "  %s %s ${c_dim}%s${c_rst}\n" "$ic" "$CUR_TITLE" "$note"
    else
      printf "  %s %s\n" "$ic" "$CUR_TITLE"
    fi
  fi
  return 0
}

# ── TUI selection / runner (shared by bootstrap.sh and dev.sh) ────────────────

# A terminal is available if stdout is a tty, or /dev/tty can be opened (covers
# `curl … | bash`, where the script's stdout is a pipe but the user still has one).
have_tty() { [ -t 1 ] && return 0; { : >/dev/tty; } 2>/dev/null; }

# tui_bin <repo-root> — resolve (build if needed) the renderer; echo path or fail.
tui_bin() {
  local root="$1"
  local dir="$root/tui"
  local bin="$dir/.bin/myra-tui"
  [ -f "$dir/main.go" ] || return 1
  if command -v go >/dev/null 2>&1; then
    if [ ! -x "$bin" ] || [ -n "$(find "$dir" -name '*.go' -newer "$bin" 2>/dev/null)" ]; then
      ( cd "$dir" && go build -o .bin/myra-tui . ) >/dev/null 2>&1 || true
    fi
  fi
  [ -x "$bin" ] && { echo "$bin"; return 0; }
  return 1
}

TUI_BIN=""
# ui_init <repo-root> <no_tui:0|1> — decide plain vs TUI. Best-effort: any miss
# (flag, no tty, no Go/binary) leaves TUI=0 and the plain path takes over.
ui_init() {
  local root="$1"
  local notui="${2:-0}"
  TUI=0; TUI_BIN=""
  [ "$notui" = 1 ] && return 0
  have_tty || return 0
  TUI_BIN="$(tui_bin "$root")" || { TUI_BIN=""; return 0; }
  TUI=1
}

# ui_run <fn> — run an event-emitting function, piping into the TUI when active.
# Returns the function's exit status (not the renderer's), so callers can react.
ui_run() {
  if [ "$TUI" = 1 ]; then
    "$1" 2>&1 | "$TUI_BIN"
    return "${PIPESTATUS[0]}"
  fi
  "$1"
}
