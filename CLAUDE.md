# Myra Agents — Dev Workspace — Claude Code Instructions

This repo is **not** application code — it is the multi-repo **bootstrap** for
the [Myra-Agents](https://github.com/orgs/Myra-Agents/repositories) org. Two
shell scripts that clone every member repo into this directory and wire them
together. Cloning this repo and running `./bootstrap.sh` produces a full dev
workspace.

```
Myra-Agents-Dev/        ← this repo (clone = workspace root)
  bootstrap.sh  dev.sh  README.md
  app/  shared/  hub/  server/  plugins/   ← cloned by bootstrap, gitignored
```

The member repos are **gitignored** (`.gitignore` lists `/app/`, `/shared/`, …)
— each is its own clone, never committed here. Only the 3 scripts + README +
this file are tracked.

## The members (and where their docs live)

| dir        | repo                | what                              | vis     |
|------------|---------------------|-----------------------------------|---------|
| `app/`     | Myra-Agents         | desktop app (Next.js 16 + Tauri)  | public  |
| `shared/`  | Myra-Agents-Shared  | `@myra/shared` types/contracts    | public  |
| `hub/`     | Myra-Agents-Hub     | Cloudflare Worker SaaS relay      | private |
| `server/`  | Myra-Agents-Server  | Rust sidecar binary               | private |
| `plugins/` | Myra-Agents-Plugins | runtime plugins                   | public  |

Each member has its own `CLAUDE.md` — read that when working **inside** a member.
This file governs only the bootstrap scripts.

## Working on the scripts

- **`bootstrap.sh`** — idempotent. Toolchain check → `gh auth setup-git` (https
  token; SSH keys may lack org access) → `git clone` each member → re-point the
  `packages/shared` submodule URL to the org → install deps. Flags: `--no-pull`,
  `--sidecar`, `--check`.
- **`dev.sh`** — thin wrappers over each member's own scripts. Targets:
  `app app-demo web hub hub-deploy server sidecar shared-pull check status pull`.

### Conventions / gotchas (these bit during authoring)

- **Target macOS bash 3.2.** `/usr/bin/env bash` resolves to 3.2 on stock macOS.
  Under `set -u`, `local a="$1" b="$ROOT/$a"` is **unbound** (can't reference `$a`
  mid-`local`) — split into separate `local` statements. `in` is a reserved word
  — don't name a function `in`.
- **Clone over https, not `gh repo clone`.** `gh repo clone` can fall back to SSH
  and fail on private org repos even with `git_protocol=https`. Use plain
  `git clone https://github.com/Myra-Agents/<repo>.git` + the gh credential helper.
- **Private repos are optional, not fatal.** `bootstrap.sh` probes access and
  **skips** `hub`/`server` when the account can't see them, so an open-source
  contributor still gets a working app+shared+plugins setup that runs against the
  **public prebuilt server binary**. Keep this property — never `die` on a private
  repo being inaccessible.
- **No Gamma-Software refs.** The org moved off the old `Gamma-Software` account;
  everything points at `Myra-Agents/`. Don't reintroduce the old namespace.
- Editing a `.github/workflows/*` file needs a gh token with the `workflow` scope
  (`gh auth refresh -s workflow --hostname github.com`) — the `--hostname` flag is
  required in non-interactive shells.

## Verify a script change

```bash
bash -n bootstrap.sh && bash -n dev.sh      # syntax
./bootstrap.sh --check                       # toolchain probe, no clone
```
