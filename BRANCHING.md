# Branching strategy (org-wide)

Applies to **every** repo in the [Myra-Agents](https://github.com/orgs/Myra-Agents/repositories)
org: app, shared, hub, server, plugins, and this dev-workspace repo.

Model: **GitFlow-lite**.

## Long-lived branches

| branch    | role                                                        |
|-----------|-------------------------------------------------------------|
| `main`    | Stable, released code. **Tagged releases only.** Never commit straight to it. |
| `develop` | **Default branch.** All day-to-day work integrates here.    |

## Short-lived branches

Branch off `develop`, PR back into `develop`:

- `feature/<slug>` — new functionality
- `fix/<slug>` — bug fixes
- `chore/<slug>` — tooling, docs, deps, refactors

Keep them short-lived and focused — one logical change per PR. PRs target
`develop` (the GitHub default), not `main`.

## Releasing

```
# when develop is release-ready
git checkout main && git merge --no-ff develop
git tag vX.Y.Z          # server repo uses server-vX.Y.Z (triggers its release CI)
git push origin main --tags
git checkout develop && git merge --no-ff main   # keep develop current
```

A push of `server-v*` on the **server** repo triggers
`release-server.yml`, which publishes the sidecar binaries to the public app
repo's Releases; then bump `server-version.json` in the app repo.

## Hotfixes

Urgent prod fix: branch `fix/<slug>` off **`main`**, PR into `main`, tag, then
merge `main` back into `develop` so the fix isn't lost.

## Conventions

- Conventional Commit subjects (`feat:`, `fix:`, `chore:`, `docs:`, …).
- Cross-repo changes (e.g. a `@myra/shared` model touching app + server) go on a
  matching `feature/<slug>` in each affected repo; mention the sibling PRs.
- Don't force-push shared branches (`main`, `develop`).
