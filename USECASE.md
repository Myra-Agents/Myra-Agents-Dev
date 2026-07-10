# Myra Agents — Use Cases

> **Purpose of this file.** Context for the agent (you, Claude). Before coding,
> designing, writing copy, or making a product trade-off on Myra, **re-read this
> and put yourself in the user's shoes**: who they are, what job they're trying to
> get done, when they open Myra. A technical decision that ignores the real use
> case is a regression, even if the code is clean.
>
> This is **not** public product docs nor a feature list. It's the mental map of
> the needs Myra serves, so every choice stays grounded in real usage.

---

## 1. What Myra is (mental model)

Myra Agents = **open-source desktop platform for scheduling AI agents** (native
macOS app, Next.js 16 + Tauri, Rust sidecar). Launch positioning: "Open-Source
desktop AI agent scheduler platform" — **not** "a Kanban that runs CLI agents."
The Kanban is a means, not the promise.

The promise: **automate the repetitive grunt work while you sleep.** You describe a
task once, Myra runs an agent (Claude Code, opencode, …) that executes it on its
own, on schedule, on your Mac, with access to your tools.

The value flow, always the same:

```
TRIGGER      →  AGENT        →  TOOLS          →  OUTPUT
(when?)         (who?)          (with what?)      (what it produces)

 time/cron      Claude Code      local repo        Slack report
 event (Slack)  opencode         Slack, Stripe     PR / commit
 manual         CLI agent        GitHub, MCP       digest, file
```

A Myra use case = **filling these 4 boxes.** When you design a feature, ask which
of the 4 you're touching and what it changes for the user at the end of the chain.

---

## 2. The personas (ordered product reality → vision)

| Persona | What they want | Product state today |
|---|---|---|
| **Developer** | Delegate bugs, PRs, tests, review, security on their repos | **Mature core** — ~75% of the use-case inventory |
| **Power user / ops** | Orchestrate recurring agents, scheduled workflows | Served by the scheduler + triggers |
| **Solo founder** | "Automate my business": reporting, churn, FAQ, finance | Served by ~6 Data & Research use cases |
| **Non-dev / general public** | Dead-simple automation, no jargon | **Vision, not yet reality** — a product effort |

> **Brutal honesty (keep it in mind).** The current inventory is heavily dev/eng.
> The vision targets everyone (see memory `product-vision-non-dev`). Never claim
> Myra already serves the general public well: getting there is a **product**
> effort, not editorial or cosmetic. When you propose work, distinguish "harden the
> dev core" from "broaden toward non-dev."

---

## 3. The jobs-to-be-done (the real catalog)

Grounded in `automations.csv` + `usecases/`. The validated **core** = **scheduled
agents (cron/schedules)** and **personal/repetitive automations**. Everything else
orbits around it.

### 3.1 Core — scheduled agents & repetitive automations
The whole reason for being. A tedious task that keeps coming back → an agent that
does it alone, on a loop.
- **Daily change summary** (`Summarize changes daily`) — eng digest of the last 24h of PRs/commits, posted to Slack.
- **Slack Digest** (`Slack Digest Agent`) — daily roundup of the messages that need your attention.
- **Product Finance / Stripe** (`Product Finance Agent`) — recurring revenue/churn/reco report, read-only.
- **Product Analytics**, **Product FAQ**, **Customer health monitoring** — same recurring patterns on the solo-founder side.

### 3.2 Code review & quality
- Find critical bugs (`Find critical bugs`)
- Assign PR reviewers (`Assign PR reviewers`)
- Add test coverage (`Add test coverage`)
- Monitor engineering invariants (`Monitor engineering invariants`)
- Generate docs (`Generate docs`)

### 3.3 Security
- Scan the codebase for vulnerabilities (`Scan codebase for vulnerabilities`)
- Find vulnerabilities (`Find vulnerabilities`)
- Remediate dependency vulnerabilities (`Remediate dependency vulnerabilities`)

### 3.4 Incidents & triage
- Fix CI failures (`Fix CI failures`)
- Fix bugs reported in Slack (`Fix bugs reported in Slack`)
- Investigate PagerDuty incidents / Sentry issues / Datadog errors
- Triage Linear issues (`Triage Linear issues`)

### 3.5 Data & research (the bridge to non-dev)
The only use cases **demonstrable outside dev** today (Stripe, Slack, analytics,
FAQ, churn, daily summary). They target the solo founder, not yet the general
public. This is where broadening the audience gets decided.

---

## 4. Anatomy of a use case (the template)

Every `usecases/*` file follows the same mold. Recognize it, respect it:

1. **Role** — "You are my Slack Attention Digest assistant."
2. **Trigger** — `time` (cron) or `event` (Slack message, webhook). CSV `trigger` column.
3. **Tools** — Slack, Stripe, GitHub, MCP… CSV `tools` column. The agent only has what you wire up.
4. **Scope / steps** — precise, bounded instructions.
5. **Output format** — fixed Markdown sections, sent to a defined destination.
6. **Guardrails** — *systematic*: `read-only`, `do not invent data`, `do not modify X`,
   never send anything but the final report. **Trust is the feature.** An autonomous
   agent that writes without guardrails is a product risk, not a convenience.

When you generate or edit a use case, all 6 blocks must be present and consistent.

---

## 5. Agent reflex: put yourself in the user's shoes

Before any decision on Myra, run this checklist:

- **Who** opens this screen / triggers this flow? (dev? solo founder? non-dev?)
- **What job** are they trying to finish? (one of the §3 boxes, or a gap?)
- **When / why** does Myra run? (scheduled overnight? reacting to an event? by hand?)
- **What do they see at the end** of the chain? (a report? a PR? nothing = silent failure?)
- **Do they trust the result?** (guardrails, honesty about what the agent did/didn't do,
  no unrequested success toast — see memory `feedback_no-unrequested-toasts`).
- **Is it demonstrable?** If the product does this use case *badly*, don't showcase it.
  "We only show what the product proves."

Golden rule, inherited from the editorial line: **the result is the star, the tool is
an extra.** The user doesn't want "an agent with MCP"; they want "my reporting writes
itself." Optimize for their result, not for the machinery.

---

## 6. What Myra is not (anti-use-cases)

- Not an IDE or a real-time copilot — Myra is **async and autonomous**, it runs without you.
- Not a web no-code tool like Zapier/Make — it's a **native app that actually drives the Mac**
  (AX-driven), and that's the moat. A web dashboard you click is not the intended experience.
- Not a chatbot — you don't chat with Myra, you **delegate** a bounded task that re-runs.
