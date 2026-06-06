#!/usr/bin/env bash
#
# Myra Agents — dev run helpers. Thin wrappers over each repo's own scripts.
#
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
c_dim=$'\033[2m'; c_rst=$'\033[0m'; c_grn=$'\033[32m'

runin() {
  [ -d "$ROOT/$1" ] || { echo "✗ $1/ not present — private repo, not cloned (need org access)." >&2; exit 1; }
  ( cd "$ROOT/$1" && shift && exec "$@" )
}

usage() {
  cat <<EOF
${c_grn}Myra dev targets${c_rst}  —  ./dev.sh <target>

  app           desktop app (Tauri shell + Next dev, port 1420)
  app-demo      same, DEMO=1 (isolated demo data)
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
  code [cursor|code]  open the multi-root workspace; auto-detects Cursor/VS Code,
                pick when both exist (or set MYRA_EDITOR)

  check         run all verification gates (tsc + cargo check + biome + server build)
  status        git status across every repo
  pull          ff-pull every repo (skips dirty ones)

  ${c_dim}help          this list${c_rst}
EOF
}

case "${1:-help}" in
  app)        runin app  bun run tauri:dev ;;
  app-demo)   runin app  bun run tauri:demo ;;
  web)        runin app  bun run dev ;;
  hub)        runin hub  bun run dev ;;
  hub-deploy) runin hub  bun run deploy ;;
  server)     runin server cargo run ;;
  sidecar)    runin app  bun run sidecar:build ;;

  sign)
    [ -x "$ROOT/app/scripts/macos-sign.sh" ] || { echo "✗ app/scripts/macos-sign.sh missing — run ./bootstrap.sh first" >&2; exit 1; }
    runin app ./scripts/macos-sign.sh "${@:2}" ;;

  plugins-link)
    [ -x "$ROOT/plugins/link-plugins.sh" ] || { echo "✗ plugins/ not present — run ./bootstrap.sh first" >&2; exit 1; }
    "$ROOT/plugins/link-plugins.sh" "${@:2}" ;;

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

  shared-pull)
    for r in app hub; do
      echo "${c_grn}▶${c_rst} $r: update packages/shared"
      git -C "$ROOT/$r" submodule update --remote --merge packages/shared
    done ;;

  check)
    echo "${c_grn}▶ app: tsc${c_rst}";        runin app bun run --bun tsc --noEmit 2>/dev/null || ( cd "$ROOT/app" && npx tsc --noEmit )
    echo "${c_grn}▶ app: biome${c_rst}";      runin app bunx biome check
    echo "${c_grn}▶ app: cargo check${c_rst}"; ( cd "$ROOT/app/src-tauri" && cargo check )
    echo "${c_grn}▶ server: cargo check${c_rst}"; runin server cargo check ;;

  status)
    for d in app shared hub server plugins; do
      [ -d "$ROOT/$d/.git" ] || continue
      b=$(git -C "$ROOT/$d" branch --show-current 2>/dev/null)
      s=$(git -C "$ROOT/$d" status --porcelain | wc -l | tr -d ' ')
      printf "${c_grn}%-8s${c_rst} %-10s ${c_dim}%s dirty file(s)${c_rst}\n" "$d" "$b" "$s"
    done ;;

  pull)
    for d in app shared hub server plugins; do
      [ -d "$ROOT/$d/.git" ] || continue
      if [ -z "$(git -C "$ROOT/$d" status --porcelain)" ]; then
        echo "${c_grn}▶${c_rst} $d: pull"; git -C "$ROOT/$d" pull --ff-only --quiet || echo "  diverged, skipped"
      else echo "${c_dim}○ $d: dirty, skipped${c_rst}"; fi
    done ;;

  help|-h|--help) usage ;;
  *) echo "unknown target: $1"; echo; usage; exit 2 ;;
esac
