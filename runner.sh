#!/usr/bin/env bash
#
# Myra Agents — self-hosted GitHub Actions runner manager.
#
# GitHub retired its Intel (x86_64) macOS *hosted* runners, so the org's release
# workflows can no longer build the `x86_64-apple-darwin` artifacts on
# github.com. This provisions an Apple Silicon Mac as a self-hosted runner
# labelled `myra-x64`: it builds arm64 natively AND cross-compiles x86_64,
# replacing the dead Intel runner for both the Worker (`release-server.yml`) and
# the app (`release.yml`). The matching jobs use `runs-on: myra-x64`.
#
# One runner registered at the ORG level serves every repo. Registering at the
# org needs a gh token with `admin:org`; a single repo (`--repo NAME`) needs
# only `repo`.
#
# Usage:
#   ./runner.sh setup [--org | --repo NAME]   download + register the runner
#   ./runner.sh run                            run in the foreground (Ctrl-C stops)
#   ./runner.sh service [install|start|stop|status|uninstall]
#                                              run as a background launchd service
#   ./runner.sh status                         show config + service state
#   ./runner.sh remove                         stop, then deregister from GitHub
#   ./runner.sh --check                        probe prerequisites, change nothing
#
# Runner files live in ./.actions-runner/ (gitignored). Override with
# MYRA_RUNNER_DIR. Runner name defaults to "<host>-myra"; override with
# MYRA_RUNNER_NAME.
#
# SECURITY — self-hosted runner + PUBLIC repo: never add a `pull_request`
# trigger to a job that targets `myra-x64`, or a fork's PR could run arbitrary
# code on this Mac. The release workflows fire only on tag push /
# workflow_dispatch (maintainer actions), which is safe.
set -euo pipefail

ORG="Myra-Agents"
LABEL="myra-x64"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_DIR="${MYRA_RUNNER_DIR:-$ROOT/.actions-runner}"
RUNNER_NAME="${MYRA_RUNNER_NAME:-$(hostname -s)-myra}"
SCOPE_FILE="$RUNNER_DIR/.myra-scope"   # remembers org-vs-repo for `remove`

c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_red=$'\033[31m'; c_dim=$'\033[2m'; c_rst=$'\033[0m'
say()  { echo "${c_grn}▶${c_rst} $*"; }
warn() { echo "${c_yel}!${c_rst} $*"; }
die()  { echo "${c_red}✗ $*${c_rst}" >&2; exit 1; }

# ── helpers ──────────────────────────────────────────────────────────────────

# Map this host's CPU to GitHub's runner package arch slug.
arch_slug() {
  case "$(uname -m)" in
    arm64)  echo "osx-arm64" ;;
    x86_64) echo "osx-x64" ;;
    *) die "unsupported arch $(uname -m) — runner pkg only ships osx-arm64 / osx-x64" ;;
  esac
}

# Latest published runner version (without the leading 'v'); falls back to a
# known-good pin if the API call fails (offline / rate-limited).
runner_version() {
  local v
  v="$(gh api repos/actions/runner/releases/latest -q .tag_name 2>/dev/null || true)"
  v="${v#v}"
  [ -n "$v" ] && { echo "$v"; return 0; }
  warn "couldn't fetch latest runner version — pinning 2.321.0" >&2
  echo "2.321.0"
}

# Token scopes attached to the active gh login (from the API response header).
gh_scopes() { gh api -i user 2>/dev/null | awk -F': ' 'tolower($1)=="x-oauth-scopes"{print $2}' | tr -d '\r'; }

# ── prerequisite probe (no side effects) ─────────────────────────────────────
check() {
  local scope="${1:-org}" name="${2:-}"
  local ok=1
  say "Prerequisites (scope: ${scope}${name:+ $ORG/$name})"

  for t in gh git curl tar; do
    if command -v "$t" >/dev/null 2>&1; then printf "  ${c_grn}✓${c_rst} %s\n" "$t"
    else printf "  ${c_red}✗${c_rst} %s missing\n" "$t"; ok=0; fi
  done

  # build toolchain the workflows need on this runner
  if command -v cargo >/dev/null 2>&1; then printf "  ${c_grn}✓${c_rst} cargo %s\n" "${c_dim}$(cargo --version 2>&1)${c_rst}"
  else printf "  ${c_red}✗${c_rst} cargo missing — https://rustup.rs\n"; ok=0; fi
  if command -v bun >/dev/null 2>&1; then printf "  ${c_grn}✓${c_rst} bun   %s\n" "${c_dim}$(bun --version 2>&1)${c_rst}"
  else printf "  ${c_yel}○${c_rst} bun missing — needed only for the app build (https://bun.sh)\n"; fi

  # x86_64 target is what makes this runner useful; the workflow adds it too, but
  # flag it so the first build doesn't surprise.
  if command -v rustup >/dev/null 2>&1; then
    if rustup target list --installed 2>/dev/null | grep -q x86_64-apple-darwin; then
      printf "  ${c_grn}✓${c_rst} rust target x86_64-apple-darwin\n"
    else
      printf "  ${c_yel}○${c_rst} rust target x86_64-apple-darwin not installed — run: rustup target add x86_64-apple-darwin\n"
    fi
  fi

  [ "$(uname -m)" = arm64 ] \
    && printf "  ${c_grn}✓${c_rst} Apple Silicon — builds arm64 native + x86_64 cross\n" \
    || warn "host is $(uname -m) (Intel) — fine for x86_64, but it can't also build arm64"

  if ! gh auth status >/dev/null 2>&1; then
    printf "  ${c_red}✗${c_rst} gh not authenticated — run: gh auth login\n"; ok=0
  elif [ "$scope" = org ]; then
    case " $(gh_scopes) " in
      *" admin:org "*) printf "  ${c_grn}✓${c_rst} gh token has admin:org (org registration)\n" ;;
      *) printf "  ${c_yel}○${c_rst} gh token lacks admin:org (needed for org-level setup)\n"
         printf "       grant it:  ${c_dim}gh auth refresh -s admin:org --hostname github.com${c_rst}\n"
         printf "       or use a single repo:  ${c_dim}./runner.sh setup --repo Worker${c_rst}\n" ;;
    esac
  fi

  [ "$ok" = 1 ] || return 1
}

# ── api base + config url for the chosen scope ───────────────────────────────
# Echoes "<api_base>|<config_url>". org → orgs/<org> ; repo → repos/<org>/<name>.
scope_endpoints() {
  local scope="$1" name="${2:-}"
  if [ "$scope" = repo ]; then
    [ -n "$name" ] || die "--repo needs a repository name"
    echo "repos/$ORG/$name|https://github.com/$ORG/$name"
  else
    echo "orgs/$ORG|https://github.com/$ORG"
  fi
}

reg_token()    { gh api --method POST "$1/actions/runners/registration-token" -q .token; }
remove_token() { gh api --method POST "$1/actions/runners/remove-token"       -q .token; }

# ── setup: download + register ───────────────────────────────────────────────
setup() {
  local scope="org" name=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --org)  scope="org" ;;
      --repo) scope="repo"; shift; name="${1:-}" ;;
      *) die "setup: unknown arg '$1' (use --org or --repo NAME)" ;;
    esac
    shift
  done

  check "$scope" "$name" || die "fix the prerequisites above, then re-run."

  local ep api_base url
  ep="$(scope_endpoints "$scope" "$name")"
  api_base="${ep%%|*}"; url="${ep##*|}"

  mkdir -p "$RUNNER_DIR"

  # Download + unpack the runner only if it isn't already there.
  if [ ! -x "$RUNNER_DIR/config.sh" ]; then
    local slug ver pkg
    slug="$(arch_slug)"; ver="$(runner_version)"
    pkg="actions-runner-${slug}-${ver}.tar.gz"
    say "download actions-runner ${ver} (${slug})"
    curl -fSL -o "$RUNNER_DIR/$pkg" \
      "https://github.com/actions/runner/releases/download/v${ver}/${pkg}" \
      || die "runner download failed"
    tar -xzf "$RUNNER_DIR/$pkg" -C "$RUNNER_DIR" && rm -f "$RUNNER_DIR/$pkg"
  else
    say "runner already unpacked in $RUNNER_DIR"
  fi

  # launchd starts services with a minimal PATH; capture the interactive PATH so
  # the background service can still find cargo / bun / rustc when it builds.
  # Sanitize first: drop pyenv/rbenv `shims` dirs (their shadow `xattr` breaks
  # Tauri's `xattr -cr` bundle step) and force the system bins ahead of the rest,
  # while keeping cargo/bun/rustc dirs reachable.
  local clean_path="" seg
  local IFS=':'
  for seg in $PATH; do
    case "$seg" in
      */shims|*/shims/) continue ;;          # pyenv/rbenv interpreter shims
      /usr/bin|/bin|/usr/sbin|/sbin) continue ;;  # re-added up front below
      "") continue ;;
    esac
    clean_path="${clean_path:+$clean_path:}$seg"
  done
  printf '%s\n' "/usr/bin:/bin:/usr/sbin:/sbin${clean_path:+:$clean_path}" \
    > "$RUNNER_DIR/.path"

  say "request registration token (${api_base})"
  local token
  token="$(reg_token "$api_base")" \
    || die "registration token failed — token needs ${scope/org/admin:org}${scope/repo/admin on $ORG/$name}"

  say "configure runner '$RUNNER_NAME' → $url  [labels: $LABEL]"
  ( cd "$RUNNER_DIR" && ./config.sh \
      --url "$url" --token "$token" \
      --name "$RUNNER_NAME" --labels "$LABEL" \
      --work _work --unattended --replace ) \
    || die "config.sh failed"

  printf '%s|%s\n' "$api_base" "$url" > "$SCOPE_FILE"

  say "registered. Start it with one of:"
  echo "    ${c_dim}./runner.sh run${c_rst}                 # foreground (good for a first test)"
  echo "    ${c_dim}./runner.sh service install${c_rst}     # background launchd service"
}

run() {
  [ -x "$RUNNER_DIR/run.sh" ] || die "not set up — run: ./runner.sh setup"
  exec "$RUNNER_DIR/run.sh"
}

# Thin wrapper over the runner's own svc.sh (install/start/stop/status/uninstall).
service() {
  [ -x "$RUNNER_DIR/svc.sh" ] || die "not set up — run: ./runner.sh setup"
  local sub="${1:-status}"
  case "$sub" in
    install)
      ( cd "$RUNNER_DIR" && ./svc.sh install && ./svc.sh start )
      say "service installed + started (launchd). Check: ./runner.sh status" ;;
    start|stop|status|uninstall)
      ( cd "$RUNNER_DIR" && ./svc.sh "$sub" ) ;;
    *) die "service: unknown subcommand '$sub' (install|start|stop|status|uninstall)" ;;
  esac
}

status() {
  echo "${c_grn}runner dir${c_rst}  $RUNNER_DIR"
  if [ -f "$RUNNER_DIR/.runner" ]; then
    echo "${c_grn}configured${c_rst} yes"
    if command -v jq >/dev/null 2>&1; then
      echo "  name   $(jq -r .agentName    "$RUNNER_DIR/.runner" 2>/dev/null)"
      echo "  url    $(jq -r .gitHubUrl    "$RUNNER_DIR/.runner" 2>/dev/null)"
    fi
    echo "  labels $LABEL ${c_dim}(+ auto: self-hosted, macOS, $(uname -m | sed 's/arm64/ARM64/;s/x86_64/X64/'))${c_rst}"
    [ -f "$SCOPE_FILE" ] && echo "  scope  ${c_dim}$(cat "$SCOPE_FILE")${c_rst}"
    if [ -x "$RUNNER_DIR/svc.sh" ]; then
      echo "${c_grn}service${c_rst}"
      ( cd "$RUNNER_DIR" && ./svc.sh status 2>/dev/null ) || echo "  ${c_dim}not installed as a service${c_rst}"
    fi
  else
    echo "${c_yel}configured${c_rst} no — run: ./runner.sh setup"
  fi
}

remove() {
  [ -x "$RUNNER_DIR/config.sh" ] || die "nothing to remove (no runner in $RUNNER_DIR)"
  # stop + uninstall the service first (ignore errors if it was never installed)
  [ -x "$RUNNER_DIR/svc.sh" ] && ( cd "$RUNNER_DIR" && ./svc.sh stop; ./svc.sh uninstall ) 2>/dev/null || true

  local api_base="orgs/$ORG"
  [ -f "$SCOPE_FILE" ] && api_base="$(cut -d'|' -f1 "$SCOPE_FILE")"
  say "deregister from GitHub (${api_base})"
  local token
  token="$(remove_token "$api_base")" || die "remove token failed (token scope?)"
  ( cd "$RUNNER_DIR" && ./config.sh remove --token "$token" ) || die "config.sh remove failed"
  say "deregistered. Runner files remain in $RUNNER_DIR (delete manually if done)."
}

# ── dispatch ─────────────────────────────────────────────────────────────────
case "${1:-help}" in
  setup)    shift; setup "$@" ;;
  run)      run ;;
  service)  shift; service "$@" ;;
  status)   status ;;
  remove)   remove ;;
  --check)  check org ;;
  help|-h|--help)
    sed -n '3,33p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown command '$1' — try: ./runner.sh help" ;;
esac
