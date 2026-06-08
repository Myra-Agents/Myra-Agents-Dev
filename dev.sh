#!/usr/bin/env bash
#
# Myra Agents — dev run helpers. Thin wrappers over each repo's own scripts.
#
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# progress helpers + colors (step_begin/step_end/ui_group/ui_init/ui_run, $TUI)
. "$ROOT/tui/ui.sh"

# Pull a global --no-tui out of the args before dispatch (targets keep their own args).
NO_TUI=0; _args=()
for _a in "$@"; do
  if [ "$_a" = "--no-tui" ]; then NO_TUI=1; else _args+=("$_a"); fi
done
set -- ${_args[@]+"${_args[@]}"}
# status/pull/check render through the TUI when one is available.
ui_init "$ROOT" "$NO_TUI"

runin() {
  [ -d "$ROOT/$1" ] || { echo "✗ $1/ not present — private repo, not cloned (need org access)." >&2; exit 1; }
  ( cd "$ROOT/$1" && shift && exec "$@" )
}

usage() {
  cat <<EOF
${c_grn}Myra dev targets${c_rst}  —  ./dev.sh <target>

  app           desktop app (Tauri shell + Next dev, port 1420)
  app-demo      same, DEMO=1 (isolated demo data)
  build [debug|release]  bundle the Tauri app (default release; debug = unoptimized,
                faster compile). Output → app/src-tauri/target/{debug,release}/
  web           frontend only, browser backend  (bun run dev)
  hub           local hub (Cloudflare Worker via bun --watch)
  hub-deploy    wrangler deploy the hub
  server        Rust sidecar  (cargo run, 127.0.0.1:4319)
  sidecar       download/build the prebuilt server binary for the app
  sign [build|ci|release]  macOS code signing helper (app/scripts/macos-sign.sh)
                build = local signed build · ci = push secrets · release = tag
  shared-pull   update the shared submodule in app + hub to latest main
  plugins-link [args]  symlink this repo's plugins into ~/.myra-agents/plugins
                (passes args to plugins/link-plugins.sh: --demo --copy --unlink)
  runner [setup|run|service|status|remove|--check]  self-hosted x64 CI runner
                (provisions this Mac as the myra-x64 GitHub Actions runner)
  code [cursor|code]  open the multi-root workspace; auto-detects Cursor/VS Code,
                pick when both exist (or set MYRA_EDITOR)

  check         run all verification gates (tsc + cargo check + biome + server build)
  status        git status across every repo
  pull          ff-pull every repo (skips dirty ones)

  ${c_dim}help          this list
  --no-tui      any target — plain output, no Bubble Tea UI${c_rst}
EOF
}

# Event-emitting bodies for the multi-repo targets — run via ui_run so they
# render in the TUI when available and print plain otherwise.
do_status() {
  ui_group status "git status"
  for d in app shared hub server plugins; do
    [ -d "$ROOT/$d/.git" ] || continue
    step_begin "$d"
    b=$(git -C "$ROOT/$d" branch --show-current 2>/dev/null)
    s=$(git -C "$ROOT/$d" status --porcelain | wc -l | tr -d ' ')
    if [ "$s" = 0 ]; then step_end ok "$b · clean"; else step_end warn "$b · $s dirty"; fi
  done
}

do_pull() {
  ui_group pull "ff-pull"
  for d in app shared hub server plugins; do
    [ -d "$ROOT/$d/.git" ] || continue
    step_begin "$d"
    if [ -n "$(git -C "$ROOT/$d" status --porcelain)" ]; then step_end skip "dirty"; continue; fi
    if git -C "$ROOT/$d" pull --ff-only --quiet; then step_end ok "pulled"; else step_end warn "diverged"; fi
  done
}

do_sidecar() {
  ui_group sidecar "server sidecar"
  [ -d "$ROOT/app" ] || { step_begin "sidecar"; step_end fail "app/ not present — run ./bootstrap.sh"; return 1; }
  step_begin "download/build"
  ( cd "$ROOT/app" && bun run sidecar:build ) && step_end ok || { step_end fail; return 1; }
}

do_shared_pull() {
  ui_group shared "shared submodule → latest main"
  for r in app hub; do
    step_begin "$r"
    [ -d "$ROOT/$r/.git" ] || { step_end skip "not present"; continue; }
    git -C "$ROOT/$r" submodule update --remote --merge packages/shared && step_end ok || { step_end fail; return 1; }
  done
}

do_check() {
  ui_group check "Verification"
  [ -d "$ROOT/app" ] || { step_begin "app"; step_end fail "not present — run ./bootstrap.sh"; return 1; }
  step_begin "app: tsc"
  ( cd "$ROOT/app" && { bun run --bun tsc --noEmit 2>/dev/null || npx tsc --noEmit; } ) && step_end ok || { step_end fail; return 1; }
  step_begin "app: biome"
  ( cd "$ROOT/app" && bunx biome check ) && step_end ok || { step_end fail; return 1; }
  step_begin "app: cargo check"
  ( cd "$ROOT/app/src-tauri" && cargo check ) && step_end ok || { step_end fail; return 1; }
  if [ -d "$ROOT/server" ]; then
    step_begin "server: cargo check"
    ( cd "$ROOT/server" && cargo check ) && step_end ok || { step_end fail; return 1; }
  fi
}

# No target given: on a real terminal, offer an interactive picker (huh when the
# renderer is up, a numbered /dev/tty menu otherwise). Piped / CI / --no-tui keeps
# the plain help listing — never auto-pick a target without a human present.
if [ "$#" -eq 0 ]; then
  if [ "$NO_TUI" != 1 ] && have_tty; then
    sel="$(ui_select "Pick a target — ./dev.sh <target>" \
      app app-demo web hub server sidecar build check status pull shared-pull code help)"
    if [ -n "$sel" ]; then set -- "$sel"; else usage; exit 0; fi
  else
    usage; exit 0
  fi
fi

case "${1:-help}" in
  app)        runin app  bun run tauri:dev ;;
  app-demo)   runin app  bun run tauri:demo ;;
  build)
    # Bundle the app. Long cargo compile, plain output (no TUI) like app/web.
    # Can't exec here — we want to offer to launch the result afterwards.
    [ -d "$ROOT/app" ] || { echo "✗ app/ not present — run ./bootstrap.sh first" >&2; exit 1; }
    mode="${2:-release}"
    case "$mode" in
      release) ( cd "$ROOT/app" && bun run tauri build ) ;;
      debug)   ( cd "$ROOT/app" && bun run tauri build --debug ) ;;
      *) echo "unknown build mode '$mode' (use: debug | release)" >&2; exit 2 ;;
    esac
    # Find the launchable artifact + how to open it, per OS. tauri build emits
    # macOS .app / Windows .exe / Linux AppImage under target/<mode>/...
    base="$ROOT/app/src-tauri/target/$mode"
    artifact=""; opener=""
    case "$(uname -s)" in
      Darwin)
        artifact=$(ls -dt "$base"/bundle/macos/*.app 2>/dev/null | head -1); opener="open" ;;
      MINGW*|MSYS*|CYGWIN*)            # Windows under Git Bash / MSYS
        artifact=$(ls -dt "$base"/*.exe 2>/dev/null | head -1); opener="winstart" ;;
      *)                               # Linux (best-effort)
        artifact=$(ls -dt "$base"/bundle/appimage/*.AppImage 2>/dev/null | head -1)
        opener="xdg-open" ;;
    esac
    # Offer to launch it — prompt only on a real terminal so this degrades to a
    # no-op when piped / in CI (same /dev/tty probe as install.sh).
    if [ -n "$artifact" ]; then
      echo "${c_grn}▶${c_rst} built: ${artifact}"
      if : >/dev/tty 2>/dev/null; then
        printf "%s" "${c_dim}run it now? [y/N] ${c_rst}" >/dev/tty
        read -r ans </dev/tty || ans=""
        case "$ans" in
          [yY]*)
            case "$opener" in
              winstart) cmd //c start "" "$artifact" ;;   # detached on Windows
              *)        "$opener" "$artifact" ;;
            esac ;;
        esac
      fi
    fi ;;
  web)        runin app  bun run dev ;;
  hub)        runin hub  bun run dev ;;
  hub-deploy) runin hub  bun run deploy ;;
  server)     runin server cargo run ;;
  sidecar)    ui_run do_sidecar || exit 1 ;;

  sign)
    [ -x "$ROOT/app/scripts/macos-sign.sh" ] || { echo "✗ app/scripts/macos-sign.sh missing — run ./bootstrap.sh first" >&2; exit 1; }
    runin app ./scripts/macos-sign.sh "${@:2}" ;;

  plugins-link)
    [ -x "$ROOT/plugins/link-plugins.sh" ] || { echo "✗ plugins/ not present — run ./bootstrap.sh first" >&2; exit 1; }
    "$ROOT/plugins/link-plugins.sh" "${@:2}" ;;

  # Self-hosted CI runner manager. Passthrough — runner.sh owns the TTY (run is a
  # foreground daemon; setup/config are interactive), so it stays plain (no TUI).
  runner)
    [ -x "$ROOT/runner.sh" ] || { echo "✗ runner.sh missing — run ./bootstrap.sh first" >&2; exit 1; }
    "$ROOT/runner.sh" "${@:2}" ;;

  code)
    ws="$ROOT/myra.code-workspace"
    [ -f "$ws" ] || { echo "✗ $ws missing — run ./bootstrap.sh first" >&2; exit 1; }
    want="${2:-${MYRA_EDITOR:-}}"            # explicit arg or MYRA_EDITOR env
    have_cursor=0; have_code=0
    command -v cursor >/dev/null 2>&1 && have_cursor=1
    command -v code   >/dev/null 2>&1 && have_code=1
    case "$want" in
      cursor)      bin=cursor ;;
      code|vscode) bin=code ;;
      "")
        if [ "$have_cursor" = 1 ] && [ "$have_code" = 1 ]; then
          echo "${c_dim}Cursor and VS Code both found — defaulting to Cursor.${c_rst}"
          echo "${c_dim}  pick: ./dev.sh code code   (or: export MYRA_EDITOR=code)${c_rst}"
          bin=cursor
        elif [ "$have_cursor" = 1 ]; then bin=cursor
        elif [ "$have_code" = 1 ];   then bin=code
        else bin="" ; fi ;;
      *) echo "unknown editor '$want' (use: cursor | code)" >&2; exit 2 ;;
    esac
    [ -n "$bin" ] || { echo "open manually (no cursor/code CLI on PATH): $ws"; exit 1; }
    command -v "$bin" >/dev/null 2>&1 || { echo "✗ '$bin' CLI not on PATH" >&2; exit 1; }
    echo "${c_grn}▶${c_rst} opening in ${bin}..."; "$bin" "$ws" ;;

  shared-pull) ui_run do_shared_pull || exit 1 ;;

  check)  ui_run do_check || exit 1 ;;
  status) ui_run do_status ;;
  pull)   ui_run do_pull ;;

  help|-h|--help) usage ;;
  *) echo "unknown target: $1"; echo; usage; exit 2 ;;
esac
