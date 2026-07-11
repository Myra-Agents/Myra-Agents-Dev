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

# Pre-flight for `app`: the Tauri shell ADOPTS a myra-server already listening on
# the dev port instead of spawning the freshly-built sidecar. So if one is up,
# show its version and ask whether to reuse it (skip the sidecar rebuild) or kill
# it and build + run a fresh one. Returns 0 to REUSE (caller skips the build),
# non-zero to build fresh (nothing running, or the user chose rebuild).
preflight_local_server() {
  local port="$1" health ver pid ans
  health=$(curl -fs -m1 "http://127.0.0.1:${port}/healthz" 2>/dev/null) || return 1
  ver=$(printf '%s' "$health" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')
  pid=$(lsof -nP -iTCP:"${port}" -sTCP:LISTEN -t 2>/dev/null | head -1)
  # No terminal to prompt (piped / CI) → reuse whatever's there, don't kill blind.
  if ! : >/dev/tty 2>/dev/null; then
    echo "${c_dim}[dev] reusing myra-server on :${port} (v${ver:-?}) — no tty to prompt${c_rst}" >&2
    return 0
  fi
  printf '%s\n' "${c_dim}myra-server already running on :${port} — version ${ver:-?} (pid ${pid:-?}).${c_rst}" >/dev/tty
  printf '%s' "${c_dim}[r] reuse it, or [b] build & use a fresh one (kills the old)? [r/b] ${c_rst}" >/dev/tty
  read -r ans </dev/tty || ans=r
  case "$ans" in
    b|B)
      if [ -n "$pid" ]; then
        echo "${c_dim}[dev] stopping old server (pid ${pid})…${c_rst}" >/dev/tty
        kill "$pid" 2>/dev/null || true
        local i=0
        while curl -fs -m1 "http://127.0.0.1:${port}/healthz" >/dev/null 2>&1; do
          i=$((i + 1)); [ "$i" -ge 10 ] && { kill -9 "$pid" 2>/dev/null || true; break; }
          sleep 0.5
        done
      fi
      return 1 ;; # build fresh
    *)
      echo "${c_dim}[dev] reusing the running server on :${port}${c_rst}" >/dev/tty
      return 0 ;; # reuse → skip the sidecar rebuild
  esac
}

usage() {
  cat <<EOF
${c_grn}Myra dev targets${c_rst}  —  ./dev.sh <target>

  app           desktop app (Tauri shell + Next dev, port 1420). Also testable
                from a plain browser at localhost:1420 — the sidecar is pinned to
                :4319 and the frontend points at it (set MYRA_SERVER_PORT to move).
  app-demo      same, DEMO=1 (isolated demo data)
  build [debug|release]  bundle the Tauri app (default release; debug = unoptimized,
                faster compile). Output → app/src-tauri/target/{debug,release}/
  web           frontend only, browser backend  (bun run dev)
  hub           local hub (Cloudflare Worker via bun --watch)
  hub-deploy    wrangler deploy the hub
  worker        Rust worker  (cargo run, 127.0.0.1:4319)
  sidecar       download/build the prebuilt worker binary for the app
  sign [build|ci|release]  macOS code signing helper (app/scripts/macos-sign.sh)
                build = local signed build · ci = push secrets · release = tag
  shared-pull   update the shared submodule in app + hub to latest main
  plugins-link [args]  symlink this repo's plugins into ~/.myra-agents/plugins
                (passes args to plugins/link-plugins.sh: --demo --copy --unlink)
  runner [setup|run|service|status|remove|--check]  self-hosted x64 CI runner
                (provisions this Mac as the myra-x64 GitHub Actions runner)
  code [cursor|code]  open the multi-root workspace; auto-detects Cursor/VS Code,
                pick when both exist (or set MYRA_EDITOR)

  env <start|stop|status> [win|ubuntu|all]   local QEMU VMs (docker, local-vms/)
                start boots, stop halts, status = compose ps (default: all)
                viewer: windows http://localhost:8006 · ubuntu http://localhost:8007
                ${c_dim}⚠ Apple Silicon has no KVM → software emulation (slow)${c_rst}

  check         run all verification gates (tsc + cargo check + biome + worker build)
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
  ui_group sidecar "worker sidecar"
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
    step_begin "worker: cargo check"
    ( cd "$ROOT/server" && cargo check ) && step_end ok || { step_end fail; return 1; }
  fi
}

# No target given: on a real terminal, offer an interactive picker (huh when the
# renderer is up, a numbered /dev/tty menu otherwise). Piped / CI / --no-tui keeps
# the plain help listing — never auto-pick a target without a human present.
if [ "$#" -eq 0 ]; then
  if [ "$NO_TUI" != 1 ] && have_tty; then
    sel="$(ui_select "Pick a target — ./dev.sh <target>" \
      app app-demo web hub worker sidecar build check status pull shared-pull code help)"
    if [ -n "$sel" ]; then set -- "$sel"; else usage; exit 0; fi
  else
    usage; exit 0
  fi
fi

case "${1:-help}" in
  # The Tauri shell already spawns + supervises the myra-server sidecar; we just
  # pin it to a known port (MYRA_DEV_PORT → the Rust ephemeral fallback) and bake
  # NEXT_PUBLIC_MYRA_SERVER_URL at it, so the SAME backend is reachable from a
  # plain browser at localhost:1420, not only the desktop window. Override the
  # port with MYRA_SERVER_PORT.
  app)        p="${MYRA_SERVER_PORT:-4319}"
              reuse_env=()
              preflight_local_server "$p" && reuse_env=(MYRA_SKIP_SIDECAR_BUILD=1)
              runin app env MYRA_DEV_PORT="$p" NEXT_PUBLIC_MYRA_SERVER_URL="http://127.0.0.1:$p" \
                ${reuse_env[@]+"${reuse_env[@]}"} bun run tauri:dev ;;
  app-demo)   p="${MYRA_SERVER_PORT:-4319}"
              reuse_env=()
              preflight_local_server "$p" && reuse_env=(MYRA_SKIP_SIDECAR_BUILD=1)
              runin app env MYRA_DEV_PORT="$p" NEXT_PUBLIC_MYRA_SERVER_URL="http://127.0.0.1:$p" \
                ${reuse_env[@]+"${reuse_env[@]}"} bun run tauri:demo ;;
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
  worker)     runin server cargo run ;;
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

  # Local QEMU VMs (Windows/Ubuntu) via docker compose in local-vms/. These exec
  # docker directly (own output), so plain — no TUI wrap, like app/web.
  env)
    compose="$ROOT/local-vms/docker-compose.yml"
    [ -f "$compose" ] || { echo "✗ local-vms/docker-compose.yml missing" >&2; exit 1; }
    command -v docker >/dev/null 2>&1 || { echo "✗ docker not on PATH — install Docker Desktop" >&2; exit 1; }
    sub="${2:-status}"
    # friendly name → compose service ('' = all services)
    svc=""
    case "${3:-all}" in
      win|windows) svc="windows" ;;
      ubuntu|linux) svc="ubuntu" ;;
      all|"") svc="" ;;
      *) echo "unknown env '$3' (use: win | ubuntu | all)" >&2; exit 2 ;;
    esac
    case "$sub" in
      start)
        ( cd "$ROOT/local-vms" && { [ -f .env ] || cp .env.example .env; } \
          && docker compose up -d ${svc:+$svc} )
        echo "${c_grn}▶${c_rst} viewer: windows ${c_dim}http://localhost:8006${c_rst} · ubuntu ${c_dim}http://localhost:8007${c_rst}"
        [ "$(uname -s)" = Darwin ] && echo "${c_dim}⚠ Apple Silicon has no KVM → software emulation (slow). See local-vms/README.md${c_rst}" ;;
      stop)
        ( cd "$ROOT/local-vms" && docker compose stop ${svc:+$svc} ) ;;
      status|ps)
        ( cd "$ROOT/local-vms" && docker compose ps ) ;;
      *) echo "unknown: ./dev.sh env <start|stop|status> [win|ubuntu|all]" >&2; exit 2 ;;
    esac ;;

  check)  ui_run do_check || exit 1 ;;
  status) ui_run do_status ;;
  pull)   ui_run do_pull ;;

  help|-h|--help) usage ;;
  *) echo "unknown target: $1"; echo; usage; exit 2 ;;
esac
