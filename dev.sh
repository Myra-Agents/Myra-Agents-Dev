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
  shared-pull   update the shared submodule in app + hub to latest main

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
