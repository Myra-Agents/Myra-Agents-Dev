#!/usr/bin/env bash
#
# Myra Agents — one-line installer.
#
#   curl -fsSL https://raw.githubusercontent.com/Myra-Agents/Myrastack/develop/install.sh | bash
#
# Clones the dev-workspace repo for you (no manual clone), then runs bootstrap.
# Interactive where it helps (asks via your terminal), with safe non-interactive
# defaults when piped without a TTY. Override with env / flags:
#
#   MYRA_DIR=~/code/myra   target workspace dir   (default: ~/Myrastack)
#   MYRA_REF=main          branch/tag to clone    (default: repo default)
#   curl ... | bash -s -- --sidecar --no-pull     flags passed through to bootstrap.sh
#   curl ... | bash -s -- --no-tui                plain output (skip the Bubble Tea UI)
#
# bootstrap renders its progress with a Bubble Tea TUI by default; it degrades to
# plain output automatically with --no-tui, no Go toolchain, or no /dev/tty.
#
set -euo pipefail

REPO="Myra-Agents/Myrastack"
DIR="${MYRA_DIR:-$HOME/Myrastack}"
REF="${MYRA_REF:-}"

c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_red=$'\033[31m'; c_dim=$'\033[2m'; c_rst=$'\033[0m'
say()  { echo "${c_grn}▶${c_rst} $*"; }
warn() { echo "${c_yel}!${c_rst} $*"; }
die()  { echo "${c_red}✗ $*${c_rst}" >&2; exit 1; }

# Ask on the controlling terminal even when the script itself is piped from curl.
# No TTY (CI, fully non-interactive) → return the default, never block.
ask() {
  local q="$1" def="$2" ans
  # Probe the controlling terminal; if it can't be opened (piped/CI), use the default.
  if { : >/dev/tty; } 2>/dev/null; then
    printf "%s ${c_dim}[%s]${c_rst} " "$q" "$def" > /dev/tty
    read -r ans < /dev/tty || ans=""
    echo "${ans:-$def}"
  else
    echo "$def"
  fi
}
yes() { case "$1" in [yY]|[yY][eE][sS]) return 0;; *) return 1;; esac; }

echo "${c_grn}Myra Agents — installer${c_rst}"
command -v git >/dev/null 2>&1 || die "git is required (xcode-select --install / apt install git)"

# 1. where
DIR="$(ask "Install workspace to" "$DIR")"
DIR="${DIR/#\~/$HOME}"

# 2. get the workspace repo (this replaces the manual 'git clone')
if [ -d "$DIR/.git" ]; then
  say "workspace exists — updating $DIR"
  git -C "$DIR" pull --ff-only --quiet || warn "couldn't fast-forward (local changes?) — continuing"
else
  say "cloning $REPO → $DIR"
  git clone ${REF:+--branch "$REF"} --quiet "https://github.com/$REPO.git" "$DIR" \
    || die "clone failed (check network / git)"
fi
cd "$DIR"

# The workspace now exists, so wire up the shared Bubble Tea UI and build its
# binary early — the remaining prompts render through huh, degrading to plain
# /dev/tty reads when there's no Go toolchain, no terminal, or --no-tui was piped.
NOTUI=0
for a in "$@"; do [ "$a" = "--no-tui" ] && NOTUI=1; done
if [ -f tui/ui.sh ]; then
  # shellcheck source=tui/ui.sh
  . tui/ui.sh
  ui_init "$DIR" "$NOTUI"
fi

# confirm <question> <default:y|n> — huh when the UI is up, plain ask() otherwise.
confirm() {
  local q="$1"
  local def="$2"
  if type ui_confirm >/dev/null 2>&1; then
    ui_confirm "$q" "$def"
  elif [ "$def" = y ]; then
    yes "$(ask "$q (Y/n)" "y")"
  else
    yes "$(ask "$q (y/N)" "n")"
  fi
}

# 3. choices
side=""
if confirm "Fetch the prebuilt worker binary now?" n; then side="--sidecar"; fi

# 4. run the real bootstrap (passes --sidecar + any flags you piped through)
say "running bootstrap…"
./bootstrap.sh $side "$@"

# 5. optional editor open
if confirm "Open the workspace in VS Code / Cursor now?" n; then
  ./dev.sh code || warn "couldn't open editor (no cursor/code CLI?)"
fi

# 6. manual next steps
cat <<EOF

${c_grn}✓ Done.${c_rst} Workspace at ${c_dim}$DIR${c_rst}

Next steps:
  cd $DIR
  ./dev.sh sidecar     # fetch the prebuilt worker binary (if you skipped it)
  ./dev.sh app         # run the desktop app
  ./dev.sh code        # open in VS Code / Cursor
  ./dev.sh help        # all targets
EOF
