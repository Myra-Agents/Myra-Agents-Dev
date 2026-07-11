# App onboarding — parked patch (transfer artifact)

This directory is a **temporary holding spot**, not part of the bootstrap. It
carries the first-run onboarding feature that belongs in the **app** repo
([`Myra-Agents/Myra-Agents`](https://github.com/Myra-Agents/Myra-Agents)), parked
here only because this session had push rights to `Myrastack` but not to the app
repo. Move it to the app repo and delete this directory.

## What the patch adds

A 4-step first-run onboarding wizard for the desktop app:

1. **Welcome** — what Myra is (a board that runs CLI coding agents) + card flow.
2. **Set up your agent** — detects/installs the default agent CLI (`opencode`)
   via the existing `check_binary` / `install_agent` RPCs.
3. **Choose a working folder** — the default directory agents run in.
4. **You're all set** — a setup summary before landing on the board.

Gated by a versioned `localStorage` flag (`myra:onboarding:completedVersion`) so
it shows once per install; mounted globally from the `(main)` layout; degrades
cleanly in browser dev mode; i18n in `en` + `fr`; PostHog funnel events.

Files touched (all under the app repo's `src/`):

- `src/app/(main)/_components/onboarding/onboarding-wizard.tsx` (new)
- `src/app/(main)/_components/onboarding/onboarding-bootstrap.tsx` (new)
- `src/lib/onboarding.client.ts` (new)
- `src/app/(main)/layout.tsx` (mount the bootstrap)
- `src/lib/posthog/events.ts` (funnel events)
- `src/messages/en.json`, `src/messages/fr.json` (copy)

Verified in-session: `tsc --noEmit` clean, biome clean on changed files, full
flow driven in a browser with no console errors.

## How to replay it onto the app repo

From a checkout of `Myra-Agents/Myra-Agents`, on a branch off `develop`:

```bash
# From the app repo root:
git checkout -b claude/app-onboarding-6m770i develop
git am /path/to/Myrastack/_app-onboarding-wip/0001-feat-onboarding-first-run-setup-wizard.patch
# or, if you prefer to stage without the commit metadata:
#   git apply /path/to/.../0001-feat-onboarding-first-run-setup-wizard.patch
git push -u origin claude/app-onboarding-6m770i
# then open a draft PR against develop
```

The patch is a `git format-patch` of commit `86a2fa0` and applies cleanly on top
of the app repo's `develop`. Once it's in the app repo, delete this directory
from `Myrastack`.
