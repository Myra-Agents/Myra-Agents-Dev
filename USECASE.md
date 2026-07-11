# Myra Agents — Use Cases

> **Purpose.** Context for the agent (you, Claude). Before building, designing, or
> writing copy for Myra, read these portraits and **put yourself in the user's
> shoes** — who they are, how they use Myra, and why. A clean change that ignores
> the real use case is still a regression.

## What Myra is

An open-source desktop app (macOS) that **runs AI agents for you on a schedule**.
You describe a repetitive task once; Myra runs an agent (Claude Code, opencode, …)
that does it on its own — overnight, on a timer, or on an event — with access to
your tools. **Automate the boring work while you sleep.**

---

## The users

### 1. Léa — the solo founder
**Who.** Runs a small SaaS alone. Not an engineer. Lives in Stripe, Slack, and her
inbox. Time is her scarcest resource.
**How she uses Myra.** Every morning at 7am, an agent reads her Stripe data and posts
a plain-English revenue + churn digest to her Slack. Another agent watches her support
inbox and drafts answers to the FAQs she's tired of retyping.
**Why.** She wants to *run her business, not her dashboards*. She'd never write a
script — Myra turns a recurring chore into something that just shows up done.

### 2. Marc — the developer
**Who.** Ships code daily, owns a few repos, drowns in small maintenance tasks.
**How he uses Myra.** A nightly agent scans his codebase for new vulnerabilities and
opens a PR with fixes. Another triages failing CI and Slack bug reports before he's
even awake. He reviews the results with his coffee instead of doing the grunt work.
**Why.** He wants the *tedious, well-defined tasks off his plate* so he can focus on
the hard problems. Async and autonomous beats a real-time copilot he has to babysit.

### 3. Sofia — the ops / power user
**Who.** Keeps a team running. Juggles reporting, monitoring, and follow-ups across
many tools.
**How she uses Myra.** She schedules a fleet of agents: a daily engineering digest, a
weekly metrics roundup, a monitor that pings her only when an invariant breaks. She
tunes triggers and tools per task and lets them run.
**Why.** She wants *leverage* — one person covering the work of several — by
orchestrating agents that repeat reliably without her hand on every one.

### 4. Tom — the non-dev (the vision)
**Who.** Not technical at all. Wants his computer to just *do the repetitive thing*.
**How he'd use Myra.** Point at a task in plain words — "every Friday, summarize these
files and email me" — and have it happen, no jargon, no setup.
**Why.** Automation without code. *This is where Myra is going, not where it fully is
yet* — reaching Tom is a product effort, not a coat of paint. Don't pretend the
product already serves him well.

---

## How to think about it

Every use case fills the same four slots — keep them in mind when you build:

```
TRIGGER      →  AGENT        →  TOOLS          →  OUTPUT
when it runs     which agent     what it can touch  what the user gets back
(timer/event)    (Claude Code…)  (Slack, Stripe,    (a report, a PR,
                                  GitHub, repo…)     a draft, a fix)
```

Golden rule: **the result is the star, the tool is an extra.** The user doesn't want
"an agent"; they want "my reporting writes itself." Optimize for their outcome, and
for their *trust* in it — bounded scope, honest results, no surprises.

**What Myra is not:** not an IDE or live copilot (it's async and autonomous), not a
web no-code tool like Zapier (it's a native app that really drives the Mac), not a
chatbot (you delegate a bounded task that re-runs, you don't chat).
