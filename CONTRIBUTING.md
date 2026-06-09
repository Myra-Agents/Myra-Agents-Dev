# Contributing

Thanks for helping on Myra Agents. This repo bootstraps the whole multi-repo
workspace; see [`README.md`](./README.md) to get set up and [`BRANCHING.md`](./BRANCHING.md)
for the full branch strategy.

## Workflow (all Myra-Agents repos)

1. Branch off `develop`: `git switch -c feature/<slug>` (or `fix/` · `chore/`).
2. Make one focused change. Use Conventional Commit subjects (`feat:`, `fix:`, …).
3. Open a PR **against `develop`** (the default branch). `main` is release-only.
4. Keep `main`/`develop` force-push-free.

## Setup

```bash
git clone https://github.com/Myra-Agents/Myrastack.git
cd Myrastack && ./bootstrap.sh
```

Outside contributors without access to the private `hub`/`server` repos still get
a working **app + shared + plugins** setup — `bootstrap.sh` skips what it can't
reach, and the app runs against the public prebuilt worker binary
(`./dev.sh sidecar`).

## Verify before opening a PR

```bash
./dev.sh check      # tsc + biome + cargo check
```

Per-repo specifics live in each member's `CLAUDE.md`.
