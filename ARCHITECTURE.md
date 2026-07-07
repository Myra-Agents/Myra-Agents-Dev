# Architecture — embedded harness + hub LLM proxy

> Cross-repo target design for the "it works the moment you open it" agent stack.
> This document is the source of truth for the workstream tracked on the
> `hub-llm-proxy-arch` branch. It lives in the **bootstrap** repo because it spans
> every member (`hub`, `server`, `harness`, `app`, `shared`); each member's own
> `CLAUDE.md` covers the member-local details once the code lands.

## Guiding idea

**The hub becomes an OpenAI-compatible LLM proxy.** The shared OpenRouter key, the
per-user quota, and the fallback cascade all live server-side. The embedded agent
harness knows exactly **one** URL — the hub — and carries **zero secrets** on the
user's machine. The only thing a user installs is the desktop app (`.dmg`); it
bundles the Rust worker, which bundles the harness.

## Target architecture

```
App Tauri (.dmg — the only thing installed)
 └─ Worker Rust (sidecar, already bundled)
     ├─ embed: myra-harness  (deepagents, bun-compiled, include_bytes!)
     │   └─ extracted once → ~/.myra-agents/bin/harness-<ver>/ → spawn
     │       └─ speaks JSON-lines on stdout ──► agent-runs/*.log + /events
     └─ the harness hits ONE LLM endpoint = the hub
         └─ Hub Nest (CF Worker): proxy POST /v1/chat/completions
             ├─ injects the real (shared) OpenRouter key
             ├─ per-user quota + fallback cascade (429 → next model)
             └─► OpenRouter
```

## Phase 0 — decisions locked

| Topic | Decision |
|---|---|
| Worker ↔ harness protocol | **JSON-lines on stdout.** The worker already streams line-by-line (`server/src/runner.rs`); no local HTTP server to supervise. |
| Where the fallback cascade lives | **Hub, not the harness.** The hub sees the 429s, retries server-side, and the logic stays centralized and patchable without shipping a new app release. |
| Git worktree for the harness | **Off by default.** Non-dev use cases aren't git repos. |
| Embed compression | **zstd** (≈64 MB → ~30 MB estimate). |

## Phase 1 — `harness/` repo (Antenna) — foundation, independent

New org member repo, wired into `bootstrap.sh` symmetrically to `server/` (**done** —
the `harness:Antenna` entry in `REPOS`, plus `dev.sh harness`, `index.sh`, the
`bun install` step, the code-workspace folder, and the summary row). Repo contents
to build:

1. `createDeepAgent` + `FilesystemBackend`; `ChatOpenAI` configured with
   `baseURL = $MYRA_HUB_URL/v1`, `apiKey = $MYRA_CREDENTIAL`.
2. JSON-lines CLI: read a task on stdin (`{prompt, cwd, runId}`), emit events
   (`{type: "tool_call" | "tool_result" | "message" | "final" | "error", …}`) on stdout.
3. GitHub CI: `bun build --compile --target` for the 5 targets
   (darwin-arm64/x64, windows-x64, linux-x64) → release `harness-vX.Y.Z` → public
   dist repo (mirrors `Myra-Agents-Server-Dist`).

**Deliverable:** a downloadable binary, testable in isolation with a real key.

## Phase 2 — hub LLM proxy — independent, curl-testable

In `hub/` (Nest CF Worker):

1. `POST /v1/chat/completions`, OpenAI-compatible (what `ChatOpenAI` calls).
2. Auth by Myra credential (enrollment mechanism already exists — `hub-credential.json`).
3. **Cascade:** free-model list served dynamically (`GET openrouter.ai/api/v1/models`,
   filter `:free` + `tools`), ranked by **observed success rate** (not by context —
   the lesson from the 429s). On 429 / provider error → retry the next model,
   transparent to the harness.
4. **Per-user quota** (KV/DO): a guardrail on the shared key. BYOK override for power users.
5. SSE streaming re-forwarded.

**Deliverable:** `curl $HUB/v1/chat/completions` works with fallback, no app needed.

## Phase 3 — worker embed + spawn + events — depends on P1

In `server/`:

1. CI downloads the harness binary (as `build-sidecar.mjs` does for the server) →
   `include_bytes!` zstd.
2. Versioned extraction to `~/.myra-agents/bin/harness-<ver>/` on first run (the
   worker writes the bytes → no quarantine; validated at POC).
3. New agent path `myra-embedded` in the existing multi-agent picker (beside
   claude / opencode).
4. Spawn + parse JSON-lines stdout → map onto `agent-log-appended` frames +
   `agent-runs/{runId}.log` (reuse the existing streaming infra).

**Deliverable:** end-to-end run from the worker, no externally-installed agent binary.

## Phase 4 — app + shared — depends on P3

1. `shared/` (Pheromones): new agent type + harness event types in the contracts.
2. `app/`: the embedded harness shows up as the default agent, **pre-selected**
   (the heart of the "works on open" vision).
3. Onboarding: Myra login → hub quota active → first run. No "install X" step.

## Thin vertical MVP first

De-risk with one end-to-end slice before widening any phase:

> harness hello-world (P1) → hub proxy, 1 model + basic fallback (P2) → worker spawn
> + 1 mapped event (P3) → a button in the app (P4)

Then thicken each phase.

## Risks & blind spots

- **Bun compat of the LangGraph stack** — validated at smoke test; re-verify on every
  deepagents bump (pin strictly).
- **Tauri updater weight** — +30 MB per update (the updater does no delta). If painful
  → switch to download-on-first-run (fallback already scoped).
- **Shared-key cost** — the P2 quota is **not** optional; overages come out of our
  pocket. Wire it day one, not later.
- **Free-tier availability** — structurally unstable. The cascade must degrade cleanly
  (a "try again" message, not a crash) when everything is saturated.
- **Sandbox / tool execute** — deepagents exposes `SandboxBackendProtocolV2`, the anchor
  point for UI approval of tool calls. Out of MVP scope, but don't close it off
  architecturally.

## Suggested start order

**P1 and P2 in parallel** (independent), then P3, then P4.

## Status in this repo

The bootstrap repo carries the **workspace-integration** slice of Phase 1: the
`harness/` member (org repo `Antenna`) is wired into `bootstrap.sh`, `dev.sh`,
`index.sh`, `.gitignore`, the member tables, and the code-workspace generator. The
member registration itself landed in #22; this branch adds the remaining tooling
depth (`dev.sh harness` target + status/pull wiring, the indexer member, the
`bun install` step, the code-workspace folder, and the summary row) and this design
document. The actual harness/hub/worker/app code lands in those member repos, tracked
by the phases above.
