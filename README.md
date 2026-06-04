# Myra Agents — dev workspace

Multi-repo dev setup for the [Myra-Agents](https://github.com/orgs/Myra-Agents/repositories) org.
Idempotent scripts that clone everything from the org and wire it together.

## One-line install (no manual clone)

```bash
curl -fsSL https://raw.githubusercontent.com/Myra-Agents/Myra-Agents-Dev/develop/install.sh | bash
```

Clones this repo for you, then runs bootstrap. Asks a couple of questions on your
terminal (with safe defaults when piped). Override:

```bash
curl -fsSL .../install.sh | MYRA_DIR=~/code/myra bash -s -- --sidecar
```

## Or clone + run manually

```bash
git clone https://github.com/Myra-Agents/Myra-Agents-Dev.git
cd Myra-Agents-Dev
./bootstrap.sh          # clone/update all repos, wire submodules, install deps
./bootstrap.sh --check  # toolchain check only
./bootstrap.sh --sidecar# also fetch the prebuilt server binary for the app
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

| dir        | repo                  | what                                   | vis     |
|------------|-----------------------|----------------------------------------|---------|
| `app/`     | Myra-Agents           | desktop app (Next.js 16 + Tauri v2)    | public  |
| `shared/`  | Myra-Agents-Shared    | `@myra/shared` TS types/contracts      | public  |
| `hub/`     | Myra-Agents-Hub       | Cloudflare Worker SaaS relay (Clerk)   | private |
| `server/`  | Myra-Agents-Server    | Rust sidecar binary (agent runner)     | private |
| `plugins/` | Myra-Agents-Plugins   | runtime plugins (lang-agnostic)        | public  |

`shared/` is also pulled in as the `packages/shared` git submodule of **app** and **hub**
(bootstrap re-points the submodule URL from the old `Gamma-Software` namespace to the org).
The Rust **server** is consumed by the app as a *prebuilt binary* (`./dev.sh sidecar`), not built from source here.

## Open-source contributors (no private access)

`bootstrap.sh` **probes access and skips** `hub/` + `server/` if your account can't see
them — it does not fail. You still get a fully working **app + shared + plugins** setup:

```bash
./bootstrap.sh     # clones app/shared/plugins, skips hub/server with a notice
./dev.sh sidecar   # fetches the PUBLIC prebuilt server binary
./dev.sh app       # runs the desktop app — no private source needed
```

The app never contains server/hub source; it talks to the prebuilt sidecar binary published
on the public app repo's Releases. `hub`/`server` dev targets print a clear message if you
run them without those repos cloned.

## Run targets (`./dev.sh <target>`)

| target       | does                                                    |
|--------------|---------------------------------------------------------|
| `app`        | desktop app — Tauri shell + Next dev (port 1420)        |
| `app-demo`   | same, `DEMO=1` (isolated demo data)                     |
| `web`        | frontend only, browser stand-in backend                |
| `hub`        | local hub (Cloudflare Worker, `bun --watch`)            |
| `hub-deploy` | `wrangler deploy` the hub                               |
| `server`     | Rust sidecar — `cargo run`, 127.0.0.1:4319              |
| `sidecar`    | download/build the prebuilt server binary for the app  |
| `shared-pull`| bump the shared submodule in app+hub to latest `main`   |
| `check`      | all gates: tsc + biome + cargo check (app & server)     |
| `status`     | git status across every repo                            |
| `pull`       | ff-pull every repo (skips dirty ones)                   |

## Prereqs

bun, Rust (cargo), Node 20+, gh (authenticated), git. `wrangler` optional — hub uses `bunx wrangler`.
Private repos clone over https via the `gh` token; `bootstrap.sh` runs `gh auth setup-git` for you
(SSH keys may not be authorized for the org).

> This workspace dir is not itself a git repo — just the two scripts. Each subdir is its own clone.
