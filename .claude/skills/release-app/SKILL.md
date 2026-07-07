---
name: release-app
description: >-
  Cut a release of the Myra Agents desktop app from the Myrastack workspace,
  guaranteeing its upstream dependencies are released and pinned first — the
  @myra/shared submodule and the myra-server sidecar. Use this whenever the user
  asks to "release the app", "cut/ship/publish an app release", "bump the app
  version", "release Myra Agents", or "make a new app version" — even if they
  don't spell out the dependency steps. The whole point is that the app CANNOT
  be released safely on its own: its CI pulls shared + the prebuilt sidecar at
  build time, so both must be released and pinned in the right order first. Also
  triggers when releasing the server/sidecar or shared as part of getting the
  app out. Do NOT use for releasing hub, plugins, or the landing site.
---

# Release the Myra Agents app (with dependencies)

The desktop **app** is the org's shippable deliverable, but it sits on top of two
upstream repos and **pulls both at CI build time**:

- **`@myra/shared`** — a git submodule at `app/packages/shared`. The build reads
  the pinned submodule commit.
- **`myra-server`** (the sidecar) — a **prebuilt binary**, not source. App CI runs
  `scripts/build-sidecar.mjs`, which reads `app/server-version.json` and
  **downloads** `myra-server-<triple>` from the public
  `Myra-Agents-Server-Dist` GitHub Releases.

So the release is a **dependency-ordered cascade**, never a lone `git tag` on the
app. If you tag the app while the sidecar binary for its pinned version isn't yet
published to Dist, **app CI fails to download it and the release breaks**. Order
is load-bearing:

```
shared (if changed)  →  server/sidecar (if changed)  →  app
     released + submodule pinned      released + Dist assets live + server-version.json pinned
```

Only bump/release a dependency that actually has unreleased work. A dependency
that's already released and already pinned to its latest tag needs **no action** —
verify and move on.

## Step 0 — Assess state (always start here)

Run the bundled reporter from the workspace root. It prints, for shared/server/
app: current version, latest tag, commits unreleased since that tag, tree
cleanliness, develop↔main divergence, and whether the app's pins already point at
the latest released tags.

```bash
bash .claude/skills/release-app/scripts/release-status.sh
```

Read it and decide which of the three actually need a release. Then confirm the
plan and the version bumps with the user before doing anything that pushes a tag —
tags trigger public release CI (binaries, notarized installers) and are hard to
walk back.

**Bump level** from the unreleased commits (Conventional Commits): any `feat` →
**minor**; only `fix`/`chore`/`refactor`/`docs` → **patch**. State your proposed
numbers; let the user override.

## Step 1 — shared (only if it has unreleased work)

Skip entirely if `release-status.sh` shows shared has 0 unreleased commits AND the
app submodule already points at the latest `v*` tag.

If shared needs releasing:

1. In `shared/`: update **`shared/CHANGELOG.md`** — rename the `## [Unreleased]`
   section to `## [X.Y.Z] — YYYY-MM-DD` (today's date) and add a fresh empty
   `## [Unreleased]` above it. Then bump `package.json` `version`, commit
   `chore(release): vX.Y.Z` (changelog + version together) on `develop`, merge to
   `main`, tag `vX.Y.Z`, push `main` + tag.
2. In `app/`: move the submodule pointer to the new tag and commit it —
   ```bash
   git -C app/packages/shared fetch --tags && git -C app/packages/shared checkout vX.Y.Z
   git -C app add packages/shared     # commit later with the app version bump
   ```

The app pins shared **by submodule commit**, not by an npm range (`"@myra/shared":
"workspace:*"`), so the pointer commit is what matters.

## Step 2 — server / sidecar (only if it has unreleased work)

The `server/` directory is the **`Worker`** repo (a `git push` may print a benign
"repository moved" redirect — ignore it). Tags use the **`server-v`** prefix.

Skip if `release-status.sh` shows server has 0 unreleased commits AND
`app/server-version.json` already points at the latest `server-v*` tag.

If server needs releasing:

1. Bump the Rust version in **both** files (keep them identical):
   `server/Cargo.toml` `version = "X.Y.Z"` and the `myra-server` package stanza in
   `server/Cargo.lock`. A version-string edit needs no `cargo` run; if you do run
   `cargo check`, note cargo isn't on the non-interactive PATH — export
   `~/.cargo/bin` and check `PIPESTATUS`.
2. Commit `release: server vX.Y.Z` on `develop`, push develop, fast-forward `main`
   to develop, tag `server-vX.Y.Z`, push `main` + tag.
3. The tag fires `release-server.yml`, which cross-builds the 5 targets and
   publishes `myra-server-<triple>[.exe]` + `.sha256` to the **public**
   `Myra-Agents-Server-Dist` Releases.
4. **WAIT for that to finish and verify the assets exist** before touching the app
   tag — this is the ordering constraint:
   ```bash
   gh run list --repo Myra-Agents/Worker --workflow=release-server.yml --limit 1
   gh release view server-vX.Y.Z --repo Myra-Agents/Myra-Agents-Server-Dist \
     --json assets -q '.assets[].name'
   ```
   Expect all 5 binaries (+ `.sha256`) present. Poll until then.
5. In `app/`: bump `server-version.json` `"version"` → `"server-vX.Y.Z"` (commit
   with the app bump in Step 3).

## Step 3 — app (the release target)

1. Confirm the two pins are current (from Steps 1–2): the `packages/shared`
   submodule points at the latest shared tag, and `server-version.json` points at
   the freshly published `server-v*`.
2. **Update `app/CHANGELOG.md` first — this is load-bearing, not cosmetic.**
   Release CI's `finalize` job `awk`s the `## [X.Y.Z]` block out of `CHANGELOG.md`
   and publishes it **verbatim as the GitHub release notes**; the CHANGELOG is read
   from the **tagged** commit, so it must be committed before the tag or the release
   ships with tauri-action's generic stub body. Rename `## [Unreleased]` to
   `## [X.Y.Z] — YYYY-MM-DD` (today's date), add a fresh empty `## [Unreleased]`
   above it, and make sure the heading is exactly `## [X.Y.Z]` (matches `VERSION`,
   i.e. the tag without its `v`) at the start of the line. Fold the unreleased work
   into `### Added/Fixed/Changed`; if the section is empty, write the notes now from
   the commits since the last tag.
3. Bump the app version to the **same string in all four places**:
   `app/package.json`, `app/src-tauri/tauri.conf.json`, `app/src-tauri/Cargo.toml`,
   and the `app` package stanza in `app/src-tauri/Cargo.lock`.
4. Stage the version bumps, the `CHANGELOG.md` edit, **plus** any dependency-pin
   changes (submodule pointer, `server-version.json`) and commit `release: vX.Y.Z`
   on `develop`; push develop.
5. Merge `develop` → `main`. `main` often carries earlier `release:` commits that
   were never back-merged, so this is usually a real merge, not a fast-forward; if
   the version files conflict, keep the **new** version. Push `main`.
6. Tag `vX.Y.Z` on `main` and push the tag → fires `release.yml`, which downloads
   the sidecar, builds the signed + **notarized** macOS/Windows/Linux installers,
   and publishes the app release.
7. Back-merge `main` → `develop` (fast-forward) and push, so the next release
   starts from an aligned develop.

## Step 4 — verify & hand off

```bash
gh run list --repo Myra-Agents/Myra-Agents --workflow=release.yml --limit 1
```

- **Apple notarization can return HTTP 403** intermittently (or if the Apple dev
  agreement lapsed). It's usually transient — `gh run rerun --failed <run-id>`
  clears it; if it persists, the agreement needs re-signing at the Apple portal.
- **Updater signing-key failure** — if every platform dies at the sign step with
  `failed to decode secret key: incorrect updater private key password: Wrong
  password for that key`, that's the Tauri **updater** key, not notarize and not
  the cascade (the sidecar download + notarize can succeed just before it). The
  `TAURI_SIGNING_PRIVATE_KEY` secret and its `_PASSWORD` must be a matching pair,
  and the committed `plugins.updater.pubkey` in `tauri.conf.json` must be from the
  same keypair. Fix by rotating to a clean keypair and setting the secret straight
  from the key file (verify the blast radius first — safe only if no shipped
  release has published a working `latest.json`/`.sig`):
  ```bash
  bun x @tauri-apps/cli signer generate -w ~/.tauri/myra-updater.key --password ""   # NOT `bunx tauri` (v1, dies on sharp)
  # copy ~/.tauri/myra-updater.key.pub content into tauri.conf.json plugins.updater.pubkey, commit + push
  gh secret set TAURI_SIGNING_PRIVATE_KEY --repo Myra-Agents/Myra-Agents --body "$(cat ~/.tauri/myra-updater.key)"
  gh secret set TAURI_SIGNING_PRIVATE_KEY_PASSWORD --repo Myra-Agents/Myra-Agents --body ""
  ```
  Use `--body "$(cat …)"`, never `< file` (the shell keeps the trailing newline →
  `Invalid symbol 10` decode error). Verify a key locally before trusting CI:
  `TAURI_SIGNING_PRIVATE_KEY="$(cat KEY)" TAURI_SIGNING_PRIVATE_KEY_PASSWORD="" bun x @tauri-apps/cli signer sign FILE`.
  Only the secrets changed → **rerun** the failed run (`gh run rerun --failed <id>`),
  no re-tag. Note: a `git tag -f` re-move of a published release tag is gated as
  destructive — if the tag already shipped, cut the next patch instead.
- Report the release URLs and the CI status plainly. If notarize is still running,
  say so rather than declaring "done".

## Conventions that bite (bake these in)

- **GitFlow, org-wide.** Bump on `develop`, merge/ff to `main`, **tag on `main`**,
  back-merge `main` → `develop`. Never commit straight to `main` (admin push
  bypasses branch protection — the "Bypassed rule violations" line is expected).
- **Tag prefixes:** app + shared use `vX.Y.Z`; server uses `server-vX.Y.Z`.
- **CHANGELOG is the release notes, and it's read from the tag.** App CI's
  `finalize` job extracts the `## [X.Y.Z]` block from `app/CHANGELOG.md` and
  publishes it as the GitHub release body. Always move `[Unreleased]` → `[X.Y.Z] —
  <date>` in the **same commit that bumps the version**, before tagging. Heading
  must be `## [X.Y.Z]` with the version matching the tag minus `v`. shared keeps its
  own `CHANGELOG.md` too; server has none (Rust, no changelog).
- **The order is the whole point.** shared/sidecar must be released **and their
  artifacts available** (Dist assets for the sidecar, submodule pointer for shared)
  before the app tag, because app CI consumes them at build time.
- Each member documents its own release + branching in its `CLAUDE.md`
  ("Releases" / "Branching") — read it when a detail here is ambiguous.
- If a dependency has **no** unreleased work, don't invent a release for it; just
  confirm the app already pins its latest tag.
