#!/usr/bin/env bash
#
# Myra Agents — dev workspace bootstrap.
#
# Idempotent: clones (or updates) all org repos, wires the shared submodule to
# the org, installs deps, and verifies the toolchain. Safe to re-run.
#
# Usage:
#   ./bootstrap.sh              # full setup
#   ./bootstrap.sh --no-pull    # don't pull existing clones, just (re)wire + install
#   ./bootstrap.sh --sidecar    # also download/build the prebuilt server sidecar for the app
#   ./bootstrap.sh --check      # toolchain check only, no clone/install
#
set -euo pipefail

ORG="Myra-Agents"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED_URL="https://github.com/${ORG}/Myra-Agents-Shared.git"

# repo dir -> org repo name
REPOS=(
  "app:Myra-Agents"
  "shared:Myra-Agents-Shared"
  "hub:Myra-Agents-Hub"
  "server:Myra-Agents-Server"
  "plugins:Myra-Agents-Plugins"
)
# private repos — skipped (not fatal) when the gh account lacks access.
# An outside / open-source contributor gets a working app+shared+plugins setup;
# the app runs against the PUBLIC prebuilt server binary, so server/hub source
# is not needed to build or run it.
PRIVATE_REPOS=" hub server "
# repos that carry a packages/shared submodule
SUBMODULE_REPOS=(app hub)
SKIPPED=""

PULL=1; DO_SIDECAR=0; CHECK_ONLY=0
for a in "$@"; do
  case "$a" in
    --no-pull) PULL=0 ;;
    --sidecar) DO_SIDECAR=1 ;;
    --check)   CHECK_ONLY=1 ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done

c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_red=$'\033[31m'; c_dim=$'\033[2m'; c_rst=$'\033[0m'
say()  { echo "${c_grn}▶${c_rst} $*"; }
warn() { echo "${c_yel}!${c_rst} $*"; }
die()  { echo "${c_red}✗ $*${c_rst}" >&2; exit 1; }

# ── toolchain ────────────────────────────────────────────────────────────────
need() {
  local bin="$1" hint="$2"
  if command -v "$bin" >/dev/null 2>&1; then
    printf "  ${c_grn}✓${c_rst} %-7s %s\n" "$bin" "${c_dim}$($bin --version 2>&1 | head -1)${c_rst}"
  else
    printf "  ${c_red}✗${c_rst} %-7s missing — %s\n" "$bin" "$hint"
    return 1
  fi
}
check_tools() {
  say "Toolchain"
  local ok=1
  need bun   "https://bun.sh"            || ok=0
  need cargo "https://rustup.rs"         || ok=0
  need node  "https://nodejs.org (v20+)" || ok=0
  need gh    "https://cli.github.com"    || ok=0
  need git   "xcode-select --install"    || ok=0
  # optional
  command -v wrangler >/dev/null 2>&1 \
    && printf "  ${c_grn}✓${c_rst} %-7s %s\n" wrangler "${c_dim}$(wrangler --version 2>&1|head -1)${c_rst}" \
    || printf "  ${c_yel}○${c_rst} %-7s ${c_dim}optional — hub uses 'bunx wrangler'${c_rst}\n" wrangler
  [ "$ok" = 1 ] || die "Install the missing required tools above, then re-run."
  gh auth status >/dev/null 2>&1 || die "gh not authenticated — run: gh auth login"
  # Private org repos clone over https via the gh token (SSH keys may lack org access).
  gh config set git_protocol https >/dev/null 2>&1 || true
  gh auth setup-git >/dev/null 2>&1 || warn "gh auth setup-git failed — private clones may fail"
}

# ── repos ────────────────────────────────────────────────────────────────────
clone_or_update() {
  local dir="$1" name="$2"; local path="$ROOT/$dir"
  if [ -d "$path/.git" ]; then
    if [ "$PULL" = 1 ]; then
      if [ -z "$(git -C "$path" status --porcelain)" ]; then
        say "$dir: pull"
        git -C "$path" pull --ff-only --quiet || warn "$dir: ff pull failed (diverged?) — skipping"
      else
        warn "$dir: local changes present — skipping pull"
      fi
    else
      say "$dir: present (skip pull)"
    fi
  else
    # plain https + gh credential helper (gh repo clone may fall back to SSH, which can lack org access)
    local url="https://github.com/$ORG/$name.git"
    if ! git ls-remote "$url" >/dev/null 2>&1; then
      if [[ "$PRIVATE_REPOS" == *" $dir "* ]]; then
        warn "$dir: no access to private $ORG/$name — skipping (not needed for app/shared/plugins)"
        SKIPPED="$SKIPPED $dir"
        return 0
      fi
      die "clone $name failed (gh auth / org access?)"
    fi
    say "$dir: clone $ORG/$name"
    git clone --quiet "$url" "$path" || die "clone $name failed"
  fi
}

wire_submodule() {
  local dir="$1"; local path="$ROOT/$dir"
  [ -f "$path/.gitmodules" ] || return 0
  say "$dir: wire packages/shared → $ORG"
  git -C "$path" config -f .gitmodules submodule.packages/shared.url "$SHARED_URL"
  git -C "$path" submodule sync --quiet packages/shared
  git -C "$path" submodule update --init --quiet packages/shared || die "$dir: submodule init failed"
}

install_deps() {
  say "app: bun install"; ( cd "$ROOT/app" && bun install --silent )
  [ -d "$ROOT/hub" ]    && { say "hub: bun install";  ( cd "$ROOT/hub"    && bun install --silent ); }
  [ -d "$ROOT/server" ] && { say "server: cargo fetch"; ( cd "$ROOT/server" && cargo fetch --quiet ); }
  # shared = types only (no build); plugins = lang-agnostic samples (no install)
  return 0
}

build_sidecar() {
  say "app: download/build server sidecar"
  ( cd "$ROOT/app" && bun run sidecar:build ) || warn "sidecar build failed (release asset missing for pinned version?)"
}

# ── run ──────────────────────────────────────────────────────────────────────
check_tools
[ "$CHECK_ONLY" = 1 ] && { say "check-only: done"; exit 0; }

for entry in "${REPOS[@]}"; do clone_or_update "${entry%%:*}" "${entry##*:}"; done
for dir in "${SUBMODULE_REPOS[@]}"; do wire_submodule "$dir"; done
install_deps
[ "$DO_SIDECAR" = 1 ] && build_sidecar

present() { [ -d "$ROOT/$1" ] && printf "${c_grn}✓${c_rst}" || printf "${c_yel}○${c_rst}"; }
cat <<EOF

${c_grn}✓ Workspace ready${c_rst} at $ROOT

  $(present app)     app/      desktop app (Next.js + Tauri)   ${c_dim}public${c_rst}
  $(present shared)  shared/   @myra/shared types              ${c_dim}public · submodule of app+hub${c_rst}
  $(present hub)     hub/      Cloudflare Worker SaaS          ${c_dim}private${c_rst}
  $(present server)  server/   Rust sidecar binary             ${c_dim}private${c_rst}
  $(present plugins) plugins/  runtime plugins                 ${c_dim}public${c_rst}
EOF
if [ -n "$SKIPPED" ]; then
  cat <<EOF

${c_yel}Skipped private repo(s):${c_rst}$SKIPPED ${c_dim}(no access — fine for app/shared/plugins work).${c_rst}
The app runs fully without them: ${c_dim}./dev.sh sidecar${c_rst} fetches the PUBLIC prebuilt
server binary, then ${c_dim}./dev.sh app${c_rst}.
EOF
fi
cat <<EOF

Next:  ./dev.sh sidecar    # fetch prebuilt server binary (first run)
       ./dev.sh app        # run the desktop app
       ./dev.sh help       # all run targets
EOF
