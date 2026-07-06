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
#   ./bootstrap.sh --sidecar    # also download/build the prebuilt worker sidecar for the app
#   ./bootstrap.sh --check      # toolchain check only, no clone/install
#   ./bootstrap.sh --no-tui     # plain line-by-line output (no Bubble Tea UI)
#
# Progress renders through a small Bubble Tea TUI (tui/myra-tui) by default. It's
# best-effort: with --no-tui, no /dev/tty (piped/CI), or no Go toolchain it falls
# back to the plain output below — never fatal.
#
set -euo pipefail

ORG="Myra-Agents"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED_URL="https://github.com/${ORG}/Pheromones.git"

# repo dir -> org repo name
REPOS=(
  "app:Myra-Agents"
  "shared:Pheromones"
  "hub:Nest"
  "server:Worker"
  "plugins:Plugins"
  "harness:Harness"
)
# private repos — skipped (not fatal) when the gh account lacks access.
# An outside / open-source contributor gets a working app+shared+plugins setup;
# the app runs against the PUBLIC prebuilt worker binary, so worker/hub source
# is not needed to build or run it.
PRIVATE_REPOS=" hub server "
# repos that carry a packages/shared submodule
SUBMODULE_REPOS=(app hub)
SKIPPED=""

PULL=1; DO_SIDECAR=0; CHECK_ONLY=0; NO_TUI=0
for a in "$@"; do
  case "$a" in
    --no-pull) PULL=0 ;;
    --sidecar) DO_SIDECAR=1 ;;
    --check)   CHECK_ONLY=1 ;;
    --no-tui)  NO_TUI=1 ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done

# Cloud sessions (Claude Code on the web) set CLAUDE_CODE_REMOTE=true. There git
# auth is provided by Anthropic's proxy and `gh` may be absent — so we treat gh
# as optional and skip the gh token checks, relying on ambient git credentials.
REMOTE="${CLAUDE_CODE_REMOTE:-}"

# shared progress helpers (step_begin/step_end/ui_group/…), colors, $TUI plumbing
. "$ROOT/tui/ui.sh"

say()  { echo "${c_grn}▶${c_rst} $*"; }
warn() { echo "${c_yel}!${c_rst} $*"; }
# die marks the in-flight step failed (TUI) or prints red (plain), then aborts.
die()  {
  if [ "$TUI" = 1 ]; then
    [ -n "$CUR_STEP" ] && ev state "$CUR_STEP" fail
    ev fatal "$*"
  else
    echo "${c_red}✗ $*${c_rst}" >&2
  fi
  exit 1
}

# ── toolchain ────────────────────────────────────────────────────────────────
need() {
  local bin="$1"
  local hint="$2"
  step_begin "$bin"
  if command -v "$bin" >/dev/null 2>&1; then
    step_end ok "$($bin --version 2>&1 | head -1)"
  else
    step_end fail "missing — $hint"
    return 1
  fi
}
check_tools() {
  ui_group tools "Toolchain"
  local ok=1
  need bun   "https://bun.sh"            || ok=0
  need cargo "https://rustup.rs"         || ok=0
  need node  "https://nodejs.org (v20+)" || ok=0
  # In cloud sessions gh is optional (proxy handles git auth); elsewhere required.
  if [ -n "$REMOTE" ] && ! command -v gh >/dev/null 2>&1; then
    step_begin gh; step_end skip "optional in cloud — proxy handles git auth"
  else
    need gh    "https://cli.github.com"    || ok=0
  fi
  need git   "xcode-select --install"    || ok=0
  # optional
  step_begin wrangler
  if command -v wrangler >/dev/null 2>&1; then
    step_end ok "$(wrangler --version 2>&1 | head -1)"
  else
    step_end skip "optional — hub uses 'bunx wrangler'"
  fi
  [ "$ok" = 1 ] || die "Install the missing required tools above, then re-run."
  step_begin "gh auth"
  # Cloud: never block on a gh token — git auth comes from Anthropic's proxy.
  # Best-effort wire the https helper if gh happens to be present & authed.
  if [ -n "$REMOTE" ]; then
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
      gh config set git_protocol https >/dev/null 2>&1 || true
      gh auth setup-git >/dev/null 2>&1 || true
    fi
    step_end skip "cloud proxy handles git auth"
    return 0
  fi
  gh auth status >/dev/null 2>&1 || { step_end fail; die "gh not authenticated — run: gh auth login"; }
  # Private org repos clone over https via the gh token (SSH keys may lack org access).
  gh config set git_protocol https >/dev/null 2>&1 || true
  gh auth setup-git >/dev/null 2>&1 || warn "gh auth setup-git failed — private clones may fail"
  step_end ok "https credential helper wired"
}

# ── repos ────────────────────────────────────────────────────────────────────
clone_or_update() {
  local dir="$1"
  local name="$2"
  local path="$ROOT/$dir"
  # Some repos must be checked out on a specific branch rather than their GitHub
  # default. Worker's default is the abandoned pre-split monorepo branch; the
  # Rust crate lives on main — clone/track that so cargo works.
  local want_branch=""; [ "$dir" = server ] && want_branch="main"

  step_begin "$dir"

  if [ -d "$path/.git" ]; then
    # snap to the required branch if we got the wrong one from an earlier clone
    if [ -n "$want_branch" ] && [ "$(git -C "$path" branch --show-current)" != "$want_branch" ]; then
      git -C "$path" fetch -q origin "$want_branch" 2>/dev/null || true
      git -C "$path" checkout -q "$want_branch" 2>/dev/null \
        || git -C "$path" checkout -q -B "$want_branch" "origin/$want_branch"
    fi
    if [ "$PULL" = 1 ]; then
      # --autostash so a stale clone still fast-forwards when the only local
      # changes are build artifacts (next-env.d.ts, src-tauri/Cargo.toml, a
      # CRLF-rewritten .gitmodules, …). Without it a single dirty generated file
      # froze the workspace at an old rev forever — the pull was silently skipped.
      if git -C "$path" pull --ff-only --autostash --quiet; then
        step_end ok "pulled"
      else
        step_end warn "ff pull failed (diverged / conflicting local edits) — left as-is"
      fi
    else
      step_end ok "present (skip pull)"
    fi
  else
    # plain https + gh credential helper (gh repo clone may fall back to SSH, which can lack org access)
    local url="https://github.com/$ORG/$name.git"
    if ! git ls-remote "$url" >/dev/null 2>&1; then
      if [[ "$PRIVATE_REPOS" == *" $dir "* ]]; then
        step_end skip "no access to private $ORG/$name (not needed for app/shared/plugins)"
        SKIPPED="$SKIPPED $dir"
        return 0
      fi
      die "clone $name failed (gh auth / org access?)"
    fi
    git clone ${want_branch:+--branch "$want_branch"} --quiet "$url" "$path" || die "clone $name failed"
    step_end ok "cloned $ORG/$name${want_branch:+ ($want_branch)}"
  fi
}

wire_submodule() {
  local dir="$1"
  local path="$ROOT/$dir"
  [ -d "$path/.git" ] || return 0
  step_begin "$dir"
  [ -f "$path/.gitmodules" ] || { step_end skip "no submodule"; return 0; }
  # Only rewrite .gitmodules when the URL actually differs — an unconditional
  # write dirties the tracked file every run (and CRLF-rewrites it on Windows),
  # which then makes the next pull skip ("local changes"). sync/update below are
  # working-tree-clean regardless, so they always run.
  local cur_url
  cur_url=$(git -C "$path" config -f .gitmodules --get submodule.packages/shared.url 2>/dev/null || true)
  [ "$cur_url" = "$SHARED_URL" ] || git -C "$path" config -f .gitmodules submodule.packages/shared.url "$SHARED_URL"
  git -C "$path" submodule sync --quiet packages/shared
  git -C "$path" submodule update --init --quiet packages/shared || die "$dir: submodule init failed"
  step_end ok "packages/shared → $ORG"
}

install_deps() {
  step_begin "app: bun install"
  ( cd "$ROOT/app" && bun install --silent ) && step_end ok || { step_end fail; die "app: bun install failed"; }
  if [ -d "$ROOT/hub" ]; then
    step_begin "hub: bun install"
    ( cd "$ROOT/hub" && bun install --silent ) && step_end ok || step_end warn "failed (continuing)"
  fi
  if [ -d "$ROOT/server" ]; then
    step_begin "worker: cargo fetch"
    ( cd "$ROOT/server" && cargo fetch --quiet ) && step_end ok || step_end warn "cargo fetch failed (continuing)"
  fi
  # shared = types only (no build); plugins = lang-agnostic samples (no install)
  return 0
}

build_sidecar() {
  step_begin "worker sidecar"
  ( cd "$ROOT/app" && bun run sidecar:build ) && step_end ok "downloaded/built" \
    || step_end warn "sidecar build failed (release asset missing for pinned version?)"
}

# Generate a multi-root VS Code / Cursor workspace listing only the repos that
# are actually present (so an OSS contributor without hub/server gets a valid file).
gen_code_workspace() {
  local ws="$ROOT/myra.code-workspace"
  local folders="" first=1
  add() {
    [ -d "$ROOT/$1" ] || return 0
    [ "$first" = 1 ] && first=0 || folders="$folders,"
    folders="$folders
    { \"name\": \"$2\", \"path\": \"$1\" }"
  }
  step_begin "code-workspace"
  add app     "app · desktop (Next+Tauri)"
  add shared  "shared · @myra/shared"
  add hub     "hub · CF Worker"
  add server  "worker · Rust worker"
  add plugins "plugins"
  add .       "· workspace (scripts)"
  # rust-analyzer projects — only the present Rust crates
  local ra=""
  [ -d "$ROOT/server" ] && ra="\"server/Cargo.toml\""
  [ -d "$ROOT/app" ]    && ra="${ra:+$ra, }\"app/src-tauri/Cargo.toml\""
  cat > "$ws" <<JSON
{
  "folders": [${folders}
  ],
  "settings": {
    "files.exclude": { "**/node_modules": true, "**/target": true, "**/.next": true, "**/out": true },
    "search.exclude": { "**/node_modules": true, "**/target": true, "**/.next": true, "**/out": true, "**/bun.lock": true },
    "editor.formatOnSave": true,
    "editor.defaultFormatter": "biomejs.biome",
    "[rust]": { "editor.defaultFormatter": "rust-lang.rust-analyzer" },
    "rust-analyzer.linkedProjects": [${ra}]
  },
  "extensions": {
    "recommendations": ["biomejs.biome", "rust-lang.rust-analyzer", "tauri-apps.tauri-vscode"]
  }
}
JSON
  step_end ok "$(grep -c '"path"' "$ws") folders"
}

# Decide plain vs Bubble Tea (best-effort; ui_init handles --no-tui / no tty / no Go).
ui_init "$ROOT" "$NO_TUI"

# ── the actual work (event-emitting; piped into the TUI when active) ──────────
run_setup() {
  ui_title "Myra Agents — workspace bootstrap"
  check_tools
  if [ "$CHECK_ONLY" = 1 ]; then ui_done "✓ toolchain ok (check-only)"; return 0; fi

  ui_group repos "Repositories"
  for entry in "${REPOS[@]}"; do clone_or_update "${entry%%:*}" "${entry##*:}"; done

  ui_group subs "Submodules"
  for dir in "${SUBMODULE_REPOS[@]}"; do wire_submodule "$dir"; done

  ui_group deps "Dependencies"
  install_deps
  [ "$DO_SIDECAR" = 1 ] && build_sidecar

  ui_group fin "Finalize"
  gen_code_workspace
  ui_done "✓ Workspace ready"
}

# ── run ──────────────────────────────────────────────────────────────────────
ui_run run_setup; rc=$?
[ "$rc" -eq 0 ] || exit "$rc"
[ "$CHECK_ONLY" = 1 ] && exit 0

# ── summary (always plain; printed after the TUI exits so it stays in scrollback)
present() { [ -d "$ROOT/$1" ] && printf "${c_grn}✓${c_rst}" || printf "${c_yel}○${c_rst}"; }
cat <<EOF

${c_grn}✓ Workspace ready${c_rst} at $ROOT

  $(present app)     app/      Myra-Agents — desktop app (Next.js + Tauri)   ${c_dim}public${c_rst}
  $(present shared)  shared/   Pheromones — @myra/shared types           ${c_dim}public · submodule of app+hub${c_rst}
  $(present hub)     hub/      Nest — Cloudflare Worker SaaS             ${c_dim}private${c_rst}
  $(present server)  server/   Worker — Rust sidecar binary              ${c_dim}private${c_rst}
  $(present plugins) plugins/  Plugins — runtime plugins                 ${c_dim}public${c_rst}
EOF
if [ -n "$SKIPPED" ]; then
  cat <<EOF

${c_yel}Skipped private repo(s):${c_rst}$SKIPPED ${c_dim}(no access — fine for app/shared/plugins work).${c_rst}
The app runs fully without them: ${c_dim}./dev.sh sidecar${c_rst} fetches the PUBLIC prebuilt
worker binary, then ${c_dim}./dev.sh app${c_rst}.
EOF
fi
cat <<EOF

Next:  ./dev.sh code       # open the multi-root workspace in VS Code / Cursor
       ./dev.sh sidecar    # fetch prebuilt worker binary (first run)
       ./dev.sh app        # run the desktop app
       ./dev.sh help       # all run targets
EOF
