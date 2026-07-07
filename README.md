# Myrastack

Multi-repo dev setup for the [Myra-Agents](https://github.com/orgs/Myra-Agents/repositories) org.
Idempotent scripts that clone everything from the org and wire it together.

> **Myra** is Swedish for *ant* — a single agent is one ant, the org is the colony:
> many workers running in parallel, coordinating toward a shared goal.

## One-line install (no manual clone)

```bash
curl -fsSL https://raw.githubusercontent.com/Myra-Agents/Myrastack/develop/install.sh | bash
```

Clones this repo for you, then runs bootstrap. Asks a couple of questions on your
terminal (with safe defaults when piped). Override:

```bash
curl -fsSL .../install.sh | MYRA_DIR=~/code/myra bash -s -- --sidecar
```

## Or clone + run manually

```bash
git clone https://github.com/Myra-Agents/Myrastack.git
cd Myrastack
./bootstrap.sh          # clone/update all repos, wire submodules, install deps
./bootstrap.sh --check  # toolchain check only
./bootstrap.sh --sidecar# also fetch the prebuilt worker binary for the app
./dev.sh help           # run targets
```

`bootstrap.sh` also generates a multi-root **`myra.code-workspace`** (only the
repos you actually cloned). Open it with:

```bash
./dev.sh code           # auto-detects Cursor / VS Code
./dev.sh code code      # force VS Code when both are installed (or: export MYRA_EDITOR=code)
```

The file is per-machine (gitignored).

## Repos

| dir        | repo        | what                                   | vis     |
|------------|-------------|----------------------------------------|---------|
| `app/`     | Myra-Agents | desktop app (Next.js 16 + Tauri v2)    | public  |
| `shared/`  | Pheromones  | `@myra/shared` TS types/contracts      | public  |
| `hub/`     | Nest        | Cloudflare Worker SaaS relay (Clerk)   | private |
| `server/`  | Worker      | Rust worker binary (agent runner)      | private |
| `plugins/` | Plugins     | runtime plugins (lang-agnostic)        | public  |
| `harness/` | Antenna     | embedded agent (deepagents, bun-built) | public  |

`shared/` is also pulled in as the `packages/shared` git submodule of **app** and **hub**
(bootstrap re-points the submodule URL from the old `Gamma-Software` namespace to the org).
The Rust **worker** is consumed by the app as a *prebuilt binary* (`./dev.sh sidecar`), not built from source here.
The **harness** (`Antenna`) is a bun-compiled agent binary the worker embeds and spawns; the hub
runs an OpenAI-compatible **LLM proxy** so the harness needs only one URL and zero secrets on the
user's machine. See **[`ARCHITECTURE.md`](ARCHITECTURE.md)** for the full target design.

## Open-source contributors (no private access)

`bootstrap.sh` **probes access and skips** `hub/` + `server/` if your account can't see
them — it does not fail. You still get a fully working **app + shared + plugins** setup:

```bash
./bootstrap.sh     # clones app/shared/plugins, skips hub/server with a notice
./dev.sh sidecar   # fetches the PUBLIC prebuilt worker binary
./dev.sh app       # runs the desktop app — no private source needed
```

The app never contains worker/hub source; it talks to the prebuilt sidecar binary published
on the public app repo's Releases. `hub`/`worker` dev targets print a clear message if you
run them without those repos cloned.

## Run targets (`./dev.sh <target>`)

| target       | does                                                    |
|--------------|---------------------------------------------------------|
| `app`        | desktop app — Tauri shell + Next dev (port 1420)        |
| `app-demo`   | same, `DEMO=1` (isolated demo data)                     |
| `web`        | frontend only, browser stand-in backend                |
| `hub`        | local hub (Cloudflare Worker, `bun --watch`)            |
| `hub-deploy` | `wrangler deploy` the hub                               |
| `worker`     | Rust worker — `cargo run`, 127.0.0.1:4319               |
| `harness`    | embedded agent harness (Antenna) — JSON task on stdin   |
| `sidecar`    | download/build the prebuilt worker binary for the app  |
| `shared-pull`| bump the shared submodule in app+hub to latest `main`   |
| `check`      | all gates: tsc + biome + cargo check (app & worker)     |
| `status`     | git status across every repo                            |
| `pull`       | ff-pull every repo (skips dirty ones)                   |

## Self-hosted CI runner (`./runner.sh`)

GitHub retired its Intel macOS *hosted* runners, so the org's release workflows
can no longer build the `x86_64-apple-darwin` artifacts on github.com. `runner.sh`
turns this Apple Silicon Mac into a self-hosted runner labelled **`myra-x64`** —
it cross-compiles x86_64 — and the app's `release.yml` + Worker's
`release-server.yml` route their x86_64 macOS jobs to it (`runs-on: myra-x64`).

```bash
./runner.sh --check                 # probe prerequisites (gh scope, cargo, bun, arch)
./runner.sh setup                   # org-level (one runner serves every repo; needs admin:org)
./runner.sh setup --repo Worker   # single repo (needs only `repo` scope)
./runner.sh service install         # run it as a background launchd service
./runner.sh status                  # config + service state
./runner.sh remove                  # deregister from GitHub
```

> Runner files live in gitignored `./.actions-runner/`. **Don't** add a
> `pull_request` trigger to a `myra-x64` job on a public repo — a fork could run
> code on this Mac. The release workflows fire only on tag push / dispatch.

## Cloud sessions (Claude Code on the web)

Cloud sessions clone a **single** GitHub repo into a network-restricted sandbox,
so the bootstrap workspace doesn't materialise on its own — the member repos are
gitignored and only `bootstrap.sh` ships. To get a full workspace in the cloud,
make the environment's **setup script** run bootstrap in remote mode (git auth
comes from Anthropic's proxy, so `gh` isn't needed).

Configure it in **Settings → Environments** at [claude.ai/code](https://claude.ai/code):

- **Setup script** — paste the snippet below (runs once per environment, cached).
- **Network access** — **Full**, or **Custom** with `bun.sh`, `sh.rustup.rs`,
  `static.rust-lang.org` plus the default allowlist (GitHub, npm, crates.io).
- **Environment variables** — leave empty. `CLAUDE_CODE_REMOTE=true` is inlined in
  the script; never put secrets here (the box is shared/visible to the environment).
- **GitHub** — connect via the Claude GitHub App. Private repos (`Nest`, `Worker`)
  clone only if the connected account can see them; otherwise bootstrap **skips**
  them and the app still runs against the public worker binary.

```bash
#!/bin/bash
set -e
# The setup script runs from /tmp (cwd is NOT the repo root), so locate
# bootstrap.sh and cd to it first — a bare `./bootstrap.sh` exits 127.
BS="$(find /home/user "$HOME" /workspace -maxdepth 3 -name bootstrap.sh 2>/dev/null | head -1)"
[ -n "$BS" ] || { echo "bootstrap.sh not found"; exit 1; }
cd "$(dirname "$BS")"
command -v bun   >/dev/null || curl -fsSL https://bun.sh/install | bash
command -v cargo >/dev/null || curl -fsSL https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env" 2>/dev/null || true; export PATH="$HOME/.bun/bin:$PATH"
CLAUDE_CODE_REMOTE=true ./bootstrap.sh --no-tui   # clones members, installs deps
```

`CLAUDE_CODE_REMOTE=true` makes `bootstrap.sh` treat `gh` as optional and skip the
gh-token check (it would otherwise `die`), relying on the proxy's git credentials.

**Observed sandbox layout:** the repo lands at `/home/user/Myrastack`, the setup
script runs with `cwd=/home/user` and `$HOME=/root`, and bun + cargo are already on
the base image (the `command -v` guards make the installs no-ops). The `find … | cd`
dance is what makes the script independent of that cwd — keep it. If a future image
moves the checkout, drop `pwd; ls -la; find / -name bootstrap.sh 2>/dev/null` at the
top of the script to re-locate it.

> Heads-up: the bootstrap workspace is a poor fit for cloud sessions (one clone
> per session). For focused work, open a cloud session **directly on a member
> repo** (`Myra-Agents`, `Worker`, …) — each is self-contained.

## Prereqs

bun, Rust (cargo), Node 20+, gh (authenticated), git. `wrangler` optional — hub uses `bunx wrangler`.
Private repos clone over https via the `gh` token; `bootstrap.sh` runs `gh auth setup-git` for you
(SSH keys may not be authorized for the org).

> This workspace dir is not itself a git repo — just the two scripts. Each subdir is its own clone.
