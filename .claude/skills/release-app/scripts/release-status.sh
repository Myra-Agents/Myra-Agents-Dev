#!/usr/bin/env bash
# release-status.sh — one-shot release-readiness report for the Myra Agents app
# and its three upstream dependencies (shared submodule, Antenna embedded
# harness, server sidecar).
#
# Run from the Myrastack workspace root. Prints, per member: current version,
# latest tag, commits unreleased since that tag, working-tree cleanliness, and
# develop/main divergence — plus whether the downstream pins already point at
# the latest released shared tag, Antenna tag, and server-v* tag.
#
# Antenna isn't a bootstrap workspace member (no local clone), so its section
# is queried via `gh api` instead of local git. Needs `gh` authenticated with
# read access to Myra-Agents/Antenna and Myra-Agents/Worker (both org repos).
#
# Read-only. No fetch of secrets, no writes, no pushes. Safe to run anytime.
set -u

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
cd "$root" || { echo "cannot cd to workspace root"; exit 1; }

hr() { printf '%s\n' "────────────────────────────────────────────────────────"; }

member_state() {
  # $1 dir, $2 tag-glob (e.g. 'v*' or 'server-v*'), $3 version-file-hint
  local dir="$1" glob="$2"
  [ -d "$dir/.git" ] || { echo "  ($dir not cloned — skipping)"; return; }
  git -C "$dir" fetch -q origin 2>/dev/null
  local branch tag ahead_main
  branch="$(git -C "$dir" branch --show-current)"
  tag="$(git -C "$dir" tag --list "$glob" --sort=-creatordate | head -1)"
  echo "  branch:        $branch"
  echo "  latest tag:    ${tag:-<none>}"
  if [ -n "$tag" ]; then
    local n
    n="$(git -C "$dir" rev-list --count "$tag"..develop 2>/dev/null || echo '?')"
    echo "  unreleased:    $n commit(s) on develop since $tag"
    git -C "$dir" log --oneline "$tag"..develop 2>/dev/null | sed 's/^/    · /' | head -12
  fi
  local dirty
  dirty="$(git -C "$dir" status --porcelain | head -1)"
  echo "  working tree:  ${dirty:+DIRTY}${dirty:-clean}"
  # develop vs origin/main: left = commits on main not in develop, right = ahead
  local div
  div="$(git -C "$dir" rev-list --left-right --count origin/main...develop 2>/dev/null)"
  echo "  main<->develop: main-only/develop-ahead = ${div:-?}"
}

antenna_state() {
  # Not a workspace member — no local clone, so query via gh api instead of git.
  if ! command -v gh >/dev/null 2>&1; then
    echo "  (gh CLI not found — skipping; run \`gh auth status\` to check)"
    return
  fi
  local latest ahead
  latest="$(gh api repos/Myra-Agents/Antenna/releases/latest --jq '.tag_name' 2>/dev/null)"
  echo "  latest tag:    ${latest:-<none>}"
  if [ -n "$latest" ]; then
    ahead="$(gh api "repos/Myra-Agents/Antenna/compare/${latest}...develop" --jq '.ahead_by' 2>/dev/null)"
    echo "  unreleased:    ${ahead:-?} commit(s) on develop since $latest"
    gh api "repos/Myra-Agents/Antenna/compare/${latest}...develop" \
      --jq '.commits[] | .sha[0:7] + " " + (.commit.message | split("\n")[0])' 2>/dev/null \
      | tail -12 | sed 's/^/    · /'
  fi
}

echo "MYRA AGENTS — RELEASE STATUS"; hr

echo "Antenna (embedded harness, tags vX.Y.Z — server pins via harness-version.json)"
antenna_state
if [ -f server/harness-version.json ]; then
  echo "  server harness-version.json → $(grep -o 'v[0-9][0-9.]*' server/harness-version.json | head -1)"
fi
hr

echo "shared  (Myra-Agents-Shared, tags vX.Y.Z — app pins via packages/shared submodule)"
member_state shared 'v*'
if [ -f app/packages/shared/package.json ]; then
  pin="$(git -C app submodule status packages/shared 2>/dev/null | awk '{print $2" "$3}')"
  echo "  app submodule → $pin"
fi
hr

echo "server  (Worker repo, tags server-vX.Y.Z — app pins via server-version.json)"
member_state server 'server-v*'
if [ -f app/server-version.json ]; then
  echo "  app server-version.json → $(grep -o 'server-v[0-9.]*' app/server-version.json | head -1)"
fi
hr

echo "app     (Myra-Agents, tags vX.Y.Z — the release target)"
member_state app 'v*'
if [ -f app/package.json ]; then
  echo "  app version:   $(grep -m1 '"version"' app/package.json | grep -o '[0-9][0-9.]*')"
fi
hr
echo "Reminder: Antenna's harness assets must be published BEFORE the server tag,"
echo "and server Dist assets must be published BEFORE the app tag is pushed"
echo "(server CI embeds Antenna's binary; app CI downloads the sidecar from"
echo "Myra-Agents-Server-Dist — both at build time)."
