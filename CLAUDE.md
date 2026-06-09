# Myra Agents — Dev Workspace — Claude Code Instructions

This repo is **not** application code — it is the multi-repo **bootstrap** for
the [Myra-Agents](https://github.com/orgs/Myra-Agents/repositories) org. Two
shell scripts that clone every member repo into this directory and wire them
together. Cloning this repo and running `./bootstrap.sh` produces a full dev
workspace.

```
Myrastack/              ← this repo (clone = workspace root)
  bootstrap.sh  dev.sh  install.sh  README.md
  tui/                  ← Bubble Tea progress UI for bootstrap (Go, tracked)
  app/  shared/  hub/  server/  plugins/   ← cloned by bootstrap, gitignored
```

The member repos are **gitignored** (`.gitignore` lists `/app/`, `/shared/`, …)
— each is its own clone, never committed here. Only the 3 scripts + the `tui/`
Go module + README + this file are tracked (the compiled `tui/.bin/` is ignored).

## The members (and where their docs live)

| dir        | repo       | what                              | vis     |
|------------|------------|-----------------------------------|---------|
| `app/`     | Myra-Agents | desktop app (Next.js 16 + Tauri) | public  |
| `shared/`  | Pheromones | `@myra/shared` types/contracts    | public  |
| `hub/`     | Nest       | Cloudflare Worker SaaS relay      | private |
| `server/`  | Worker     | Rust worker binary                | private |
| `plugins/` | Plugins    | runtime plugins                   | public  |

Each member has its own `CLAUDE.md` — read that when working **inside** a member.
This file governs only the bootstrap scripts.

## Org GitHub Project (the planning board)

There is an org-level GitHub Project — **"Myra Agents"** (project #1, private):
<https://github.com/orgs/Myra-Agents/projects/1>. It's the cross-repo planning
board (Status / Team / Iteration / Quarter / Milestone fields; PRs + issues from
all member repos land here). **Refer to it whenever you need to know what's
planned, in flight, or how work is tracked across the org** — e.g. before
proposing new work, when triaging, or to find the board status of a PR/issue.

Accessing it needs a gh token with the `project` scope
(`gh auth refresh -s project --hostname github.com`). Query it via
`gh project view 1 --owner Myra-Agents` and
`gh project item-list 1 --owner Myra-Agents`.

## Working on the scripts

- **`install.sh`** — the `curl | bash` entrypoint. Clones this repo to `MYRA_DIR`
  (default `~/Myrastack`), then runs `bootstrap.sh`. Asks via `/dev/tty`
  (probed with `: >/dev/tty` so it degrades to defaults when piped/CI — never
  block). Passes flags through to bootstrap (`bash -s -- --sidecar`).
- **`bootstrap.sh`** — idempotent. Toolchain check → `gh auth setup-git` (https
  token; SSH keys may lack org access) → `git clone` each member → re-point the
  `packages/shared` submodule URL to the org → install deps. Flags: `--no-pull`,
  `--sidecar`, `--check`, `--no-tui`.
- **`tui/`** — a small Go **Bubble Tea** renderer (`tui/main.go`) for bootstrap's
  progress. bootstrap does all the real work and emits sentinel-prefixed *events*
  (`tui/ui.sh` helpers `step_begin`/`step_end`/`ui_group`/…); those are piped into
  `tui/myra-tui`, which renders a live checklist on `/dev/tty` while raw git/bun
  output becomes a dim log tail. See the TUI gotchas below.
- **`dev.sh`** — thin wrappers over each member's own scripts. Targets:
  `app app-demo web hub hub-deploy worker sidecar shared-pull check status pull`.
  The finite, step-shaped targets (`status`/`pull`/`check`/`sidecar`/`shared-pull`)
  render through the same Bubble Tea UI via `ui_run`; a global `--no-tui` (stripped
  before dispatch) forces plain. The exec targets (`app`/`web`/`hub`/`worker`/…)
  replace the process and own the TTY, so they stay plain — don't TUI-wrap them.
- **`runner.sh`** — provisions this Mac as a **self-hosted GitHub Actions runner**
  labelled `myra-x64`. GitHub retired its Intel macOS *hosted* runners, so the
  `x86_64-apple-darwin` jobs in the app's `release.yml` and the Worker's
  `release-server.yml` now `runs-on: myra-x64` — an Apple Silicon Mac that
  cross-compiles x86_64 (proven: `cargo build --target x86_64-apple-darwin`).
  Subcommands: `setup [--org|--repo NAME]`, `run`, `service`, `status`, `remove`,
  `--check`. Org-level registration needs a gh token with `admin:org`; one repo
  needs only `repo`. Runner lives in gitignored `./.actions-runner/`. **Don't add
  a `pull_request` trigger to a `myra-x64` job on a public repo** — a fork could
  run code on the Mac; the release workflows fire only on tag push / dispatch.

### Conventions / gotchas (these bit during authoring)

- **Target macOS bash 3.2.** `/usr/bin/env bash` resolves to 3.2 on stock macOS.
  Under `set -u`, `local a="$1" b="$ROOT/$a"` is **unbound** (can't reference `$a`
  mid-`local`) — split into separate `local` statements. `in` is a reserved word
  — don't name a function `in`.
- **Clone over https, not `gh repo clone`.** `gh repo clone` can fall back to SSH
  and fail on private org repos even with `git_protocol=https`. Use plain
  `git clone https://github.com/Myra-Agents/<repo>.git` + the gh credential helper.
- **Private repos are optional, not fatal.** `bootstrap.sh` probes access and
  **skips** `hub`/`worker` when the account can't see them, so an open-source
  contributor still gets a working app+shared+plugins setup that runs against the
  **public prebuilt worker binary**. Keep this property — never `die` on a private
  repo being inaccessible.
- **No Gamma-Software refs.** The org moved off the old `Gamma-Software` account;
  everything points at `Myra-Agents/`. Don't reintroduce the old namespace.
- **The TUI is best-effort, never required.** bootstrap renders with Bubble Tea
  *by default* but must degrade to the plain colored output with `--no-tui`, when
  no Go toolchain is on PATH, or when there's no terminal (`curl | bash` with no
  `/dev/tty`, CI). The `tui_bin`/`have_tty` probes in bootstrap.sh guard this —
  keep it: a failed/absent TUI must never abort setup. Events arrive on the
  renderer's **stdin** (the pipe) while display + keys use **/dev/tty**, so it
  works even when the script's own stdout is a pipe. Rebuilds the binary on demand
  into the gitignored `tui/.bin/`.
- Editing a `.github/workflows/*` file needs a gh token with the `workflow` scope
  (`gh auth refresh -s workflow --hostname github.com`) — the `--hostname` flag is
  required in non-interactive shells.

## Verify a script change

```bash
bash -n bootstrap.sh && bash -n dev.sh && bash -n tui/ui.sh   # shell syntax
(cd tui && go vet ./... && go test ./...)                      # TUI renderer
./bootstrap.sh --check                                         # toolchain probe, no clone
./bootstrap.sh --check --no-tui                                # force the plain fallback
```

## Branching

GitFlow-lite, **org-wide** across all Myra-Agents repos:

- `main` — stable, released code; **tagged releases only**, never commit straight to it.
- `develop` — **default branch**; all day-to-day work integrates here.
- `feature/<slug>` · `fix/<slug>` · `chore/<slug>` — short-lived, branch off `develop`, PR back into `develop`.
- Release: merge `develop` → `main` + tag (`vX.Y.Z`; Worker uses `worker-vX.Y.Z`).
- Hotfix: branch off `main`, PR into `main`, then merge `main` back to `develop`.

Open PRs against `develop`. Conventional Commit subjects. One logical change per PR.

> **Worker exception:** `Worker`'s `develop` is an abandoned
> pre-split *monorepo* branch (`4a801e8`, old app/Clerk/UI commits), not the Rust
> worker lineage on `main` — so its default branch currently shows pre-split
> content. Left as-is intentionally; don't realign or change its default without
> asking. Stale content is backed up at `~/Backups/Myra-Agents-monorepo.git`.
