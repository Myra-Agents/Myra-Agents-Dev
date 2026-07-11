#!/usr/bin/env bash
#
# Myra Agents — index.sh: greppable code indexes for agents.
#
# Writes .claude/index/<member>.md for each cloned member repo: directory
# list, source-file list, and a symbol index (definition lines with line
# numbers). Agents grep these files to locate code instead of re-scanning
# every repo at the start of each session.
#
#   ./index.sh                 index every cloned member
#   ./index.sh app server      index only those members
#   ./index.sh --check         report fresh/stale per member, exit 1 if stale
#   ./index.sh --quiet         silent (for hooks)
#
# Needs only git + grep (BSD ok). Safe to re-run anytime; output is gitignored.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$ROOT/.claude/index"

# "root" = this Myrastack repo itself (scripts + tui/).
MEMBERS_ALL="root app shared hub server harness plugins"

CHECK=0 QUIET=0 MEMBERS=""
for a in "$@"; do
  case "$a" in
    --check) CHECK=1 ;;
    --quiet) QUIET=1 ;;
    -h|--help) sed -n '3,15p' "$0"; exit 0 ;;
    -*) echo "unknown flag: $a" >&2; exit 2 ;;
    *) MEMBERS="$MEMBERS $a" ;;
  esac
done
[ -n "${MEMBERS// /}" ] || MEMBERS="$MEMBERS_ALL"

say() { [ "$QUIET" = 1 ] || echo "$@"; }

# Definition-line patterns, POSIX ERE (works with BSD grep and GNU grep).
# Recall over precision: a little noise is fine, a missed symbol is not.
# TS/JS: export lines anywhere, plus column-0 top-level defs (non-exported
# components/hooks/consts are half the app's definitions).
PAT_TS='^[[:space:]]*export[[:space:]]|^(async[[:space:]]+)?function[[:space:]]|^(const|let|var)[[:space:]]|^(abstract[[:space:]]+)?class[[:space:]]|^(interface|enum|namespace)[[:space:]]|^type[[:space:]]+[A-Za-z_$]'
# HTTP route registrations + pathname dispatch — "where is endpoint X handled".
PAT_ROUTES="(^|[[:space:]])(app|router)\\.(get|post|put|delete|patch|all|route)\\(|url\\.pathname"
PAT_RS='^[[:space:]]*(#[[]tauri::command|pub([(][^)]*[)])?[[:space:]]+(async[[:space:]]+)?(unsafe[[:space:]]+)?(fn|struct|enum|trait|mod|type|const|static)[[:space:]]|(async[[:space:]]+)?(unsafe[[:space:]]+)?fn[[:space:]]|(struct|enum|trait|mod|union|const|static)[[:space:]]|type[[:space:]]+[A-Za-z_]|macro_rules!|impl([[:space:]]|<))'
PAT_GO='^(func|type|const|var)[[:space:]]'
PAT_SH='^[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\(\)|^function[[:space:]]+[a-zA-Z_]'
PAT_PY='^[[:space:]]*(def|class|[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=)[[:space:]]'

# List tracked + untracked-but-not-ignored files matching the given git
# pathspecs, NUL-separated. Run from inside the member repo.
ls_src() {
  git ls-files -z -- "$@" 2>/dev/null
  git ls-files -z --others --exclude-standard -- "$@" 2>/dev/null
}

# Emit "path:line:definition" for one language group. $1=pattern, rest=pathspecs.
# `--` keeps dash-prefixed filenames from being parsed as grep options;
# grep exits 1 when a batch has no match — not an error here.
symbols() {
  pat="$1"; shift
  ls_src "$@" | xargs -0 grep -HEn -e "$pat" -- 2>/dev/null || true
}

# Extensionless executables (node/bash/python shebangs) — e.g. the plugins/
# agent scripts, which are the core code of that repo.
shebang_symbols() {
  ls_src | tr '\0' '\n' | grep -v '\.[^/]*$' | while IFS= read -r f; do
    [ -f "$f" ] || continue
    first=""; IFS= read -r first < "$f" 2>/dev/null || true
    case "$first" in
      '#!'*node*|'#!'*bun*) grep -HEn -e "$PAT_TS" -- "$f" 2>/dev/null || true ;;
      '#!'*python*)         grep -HEn -e "$PAT_PY" -- "$f" 2>/dev/null || true ;;
      '#!'*sh*)             grep -HEn -e "$PAT_SH" -- "$f" 2>/dev/null || true ;;
    esac
  done || true
}

all_symbols() {
  symbols "$PAT_TS" '*.ts' '*.tsx' '*.js' '*.jsx' '*.mts' '*.mjs'
  symbols "$PAT_ROUTES" '*.ts' '*.tsx' '*.js' '*.mts' '*.mjs'
  symbols "$PAT_RS" '*.rs'
  symbols "$PAT_GO" '*.go'
  symbols "$PAT_SH" '*.sh'
  symbols "$PAT_PY" '*.py'
  shebang_symbols
}

# Checked-out submodule paths of the repo at cwd (e.g. packages/shared), one
# per line. git ls-files doesn't descend into them, so they get their own pass.
sub_paths() {
  git config --file .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null \
    | sed -n 's/^submodule\..*\.path //p' || true
}

head_of() { git -C "$1" rev-parse --short HEAD 2>/dev/null || echo "none"; }

# Working-tree fingerprint: HEAD alone misses uncommitted edits (symbol line
# numbers drift while --check still says fresh). status catches the untracked
# file set; diff HEAD catches tracked content changes, staged or not. Both are
# deterministic, so the cksum is stable for an unchanged tree.
tree_fp() {
  {
    git -C "$1" status --porcelain 2>/dev/null || true
    git -C "$1" diff HEAD 2>/dev/null || true
  } | cksum | awk '{print $1}'
}

member_dir() { if [ "$1" = root ]; then echo "$ROOT"; else echo "$ROOT/$1"; fi; }

index_one() {
  m="$1"
  dir="$(member_dir "$m")"
  out="$OUT_DIR/$m.md"
  [ -e "$dir/.git" ] || { say "  ✗ $m — not cloned, skipped"; return 0; }

  hd="$(head_of "$dir")"
  fp="$(tree_fp "$dir")"
  (
    cd "$dir"
    # Newline-separated list of checked-out submodules (paths may have spaces).
    subs=""
    while IFS= read -r s; do
      [ -n "$s" ] && [ -e "$s/.git" ] && subs="$subs$s
"
    done <<EOF
$(sub_paths)
EOF

    # Trailing-slash entries are untracked nested git repos, not files.
    files="$(ls_src | tr '\0' '\n' | grep -v '/$' || true)"
    while IFS= read -r s; do
      [ -n "$s" ] || continue
      files="$files
$( (cd "$s" && ls_src | tr '\0' '\n' | grep -v '/$' || true) | sed "s|^|$s/|")"
    done <<EOF
$subs
EOF

    {
      echo "# index: $m — HEAD $hd — tree $fp — $(date +%Y-%m-%d)"
      echo "# Greppable code index. grep this file to locate dirs/files/symbols;"
      echo "# do NOT read it whole. Paths are relative to $m/."
      [ -n "$subs" ] && echo "# Includes checked-out submodule(s): $(printf '%s' "$subs" | tr '\n' ' ')(their own pinned rev, may differ from the sibling clone)."
      echo "# Regenerate: ./index.sh $m"
      echo
      echo "## dirs"
      printf '%s\n' "$files" | grep / | sed 's|/[^/]*$||' | cut -d/ -f1-4 | sort -u || true
      echo
      echo "## files"
      printf '%s\n' "$files" | grep -v '^$' | sort || true
      echo
      echo "## symbols"
      # cut: embedded-blob consts (multi-KB single lines) would drown greps.
      {
        all_symbols
        while IFS= read -r s; do
          [ -n "$s" ] || continue
          (cd "$s" && all_symbols | sed "s|^|$s/|")
        done <<EOF
$subs
EOF
      } | sort -u | cut -c1-250
    } > "$out"
  )
  say "  ✓ $m — HEAD $hd → .claude/index/$m.md ($(wc -l < "$out" | tr -d ' ') lines)"
}

check_one() {
  m="$1"
  dir="$(member_dir "$m")"
  out="$OUT_DIR/$m.md"
  [ -e "$dir/.git" ] || return 0
  hd="$(head_of "$dir")"
  if [ ! -f "$out" ]; then say "  ✗ $m — no index"; return 1; fi
  hdr="$(head -1 "$out")"
  case "$hdr" in
    *"HEAD $hd"*) ;;
    *) say "  ✗ $m — stale (HEAD moved)"; return 1 ;;
  esac
  # Pre-fingerprint index files lack the "tree" token — regenerate once.
  rec="$(printf '%s\n' "$hdr" | sed -n 's/.* tree \([0-9][0-9]*\) .*/\1/p')"
  if [ -z "$rec" ]; then say "  ✗ $m — stale (no tree fingerprint)"; return 1; fi
  if [ "$rec" != "$(tree_fp "$dir")" ]; then say "  ✗ $m — stale (dirty tree changed)"; return 1; fi
  if ! grep -q '^## symbols' "$out"; then say "  ✗ $m — truncated"; return 1; fi
  say "  ✓ $m — fresh"
}

mkdir -p "$OUT_DIR"
rc=0
for m in $MEMBERS; do
  if [ "$CHECK" = 1 ]; then check_one "$m" || rc=1; else index_one "$m"; fi
done
exit "$rc"
