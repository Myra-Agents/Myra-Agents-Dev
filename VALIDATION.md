# Plugin Instances + E2E Sync — Validation Runbook

Reproduces what was tested during validation. Branches:
- Phase 1: `feature/plugin-instances` (shared, server, app)
- Phase 2: `feature/e2e-sync` (shared, hub, app — branched off Phase 1)

Paths below use the worktrees that were used during validation
(`<repo>/.claude/worktrees/<branch>`). To run from your own clones instead,
`git checkout feature/plugin-instances` (or `feature/e2e-sync`) in each repo and
`git submodule update --init packages/shared`.

---

## Layer 0 — static gates (all green)

```bash
# server (Phase 1)
cd server/.claude/worktrees/plugin-instances
cargo check && cargo test                 # 18 passed

# app (Phase 2 worktree has both phases)
cd app/.claude/worktrees/e2e-sync
npx tsc --noEmit
npx biome check
bun test src/lib/sync/                     # 18 passed (crypto + merge)
(cd src-tauri && cargo check)

# hub Worker (Phase 2)
cd hub/.claude/worktrees/e2e-sync
bunx tsc --noEmit -p packages/hub/tsconfig.cf.json
bunx biome check
(cd packages/hub && bun test src/cf/do-sync-store.test.ts)   # 6 passed
```
Note: the hub's default `npx tsc` gate needs `bun` types (absent in this env) — use the `tsconfig.cf.json` Worker gate above.

---

## Layer 1 — server backend (per-instance webhooks), driven by curl

### Build + boot a scratch server
```bash
cd /Users/valentinrudloff/Workspace/Myra-Agents-Dev
SRV=server/.claude/worktrees/plugin-instances     # or server/ on the branch
(cd "$SRV" && CARGO_TARGET_DIR="$PWD/../../../target" cargo build)   # or: cargo build
BIN=server/target/debug/myra-server

SCRATCH=/tmp/myra-validate
rm -rf "$SCRATCH"; mkdir -p "$SCRATCH/plugins/slack" "$SCRATCH/plugins/github"
cp plugins/integrations/slack/manifest.json  "$SCRATCH/plugins/slack/manifest.json"
cp plugins/integrations/github/manifest.json "$SCRATCH/plugins/github/manifest.json"

# legacy single-config settings.json (to test migration)
cat > "$SCRATCH/settings.json" <<'JSON'
{ "defaultAgentId":"opencode","agents":[],"maxConcurrentAgents":2,
  "defaultHomePage":"kanban","locale":"auto","theme":"system",
  "pluginConfig": { "slack": { "WEBHOOK_URL": "https://legacy.example/hook" } } }
JSON

MYRA_DIR="$SCRATCH" PORT=4399 "$BIN" >/tmp/myra.log 2>&1 &
sleep 1; curl -s localhost:4399/healthz
rpc(){ curl -s -X POST "localhost:4399/rpc/$1" -H 'content-type: application/json' -d "$2"; }
```

### 1.1 Migration — legacy `pluginConfig` → synthesized instance
```bash
rpc get_settings '{}' | python3 -c "import sys,json;print(json.load(sys.stdin)['data']['pluginInstances'])"
# EXPECT: a 'slack' instance (id=slack, config.WEBHOOK_URL preserved, enabled=true)
```

### 1.2 Instance-scoped secrets
```bash
# add a github instance gh-eng
rpc get_settings '{}' | python3 -c "
import sys,json; s=json.load(sys.stdin)['data']
s.setdefault('pluginInstances',{})['gh-eng']={'id':'gh-eng','plugin':'github','label':'#eng','enabled':True,'config':{}}
open('/tmp/s.json','w').write(json.dumps({'settings':s}))"
rpc save_settings "$(cat /tmp/s.json)" >/dev/null
rpc set_plugin_secret '{"plugin":"gh-eng","key":"GH_SECRET","value":"s3cr3t-eng"}'
rpc plugin_secret_status '{"plugin":"gh-eng"}'   # EXPECT {"data":["GH_SECRET"],"ok":true}
rpc plugin_secret_status '{"plugin":"slack"}'    # EXPECT {"data":[],"ok":true}
```

### 1.3 Per-instance inbound route + HMAC verify
```bash
BODY='{"pull_request":{"title":"Validate inbound","body":"x"}}'
SIG=$(python3 -c "import hmac,hashlib;print('sha256='+hmac.new(b's3cr3t-eng','''$BODY'''.encode(),hashlib.sha256).hexdigest())")
curl -s -X POST localhost:4399/hooks/i/gh-eng/github -H "X-Hub-Signature-256: $SIG" -d "$BODY"          # EXPECT 200 ok
curl -s -o /dev/null -w "%{http_code}\n" -X POST localhost:4399/hooks/i/gh-eng/github -H "X-Hub-Signature-256: sha256=bad" -d "$BODY"   # EXPECT 401
curl -s -o /dev/null -w "%{http_code}\n" -X POST localhost:4399/hooks/i/nope/github  -H "X-Hub-Signature-256: $SIG" -d "$BODY"          # EXPECT 404
rpc get_cards '{}' | python3 -c "import sys,json;print([c['title'] for c in json.load(sys.stdin)['data']])"   # EXPECT ['Validate inbound']
```

### 1.4 Instance isolation + disabled gating
```bash
# add gh-sales with a DIFFERENT secret
rpc get_settings '{}' | python3 -c "
import sys,json; s=json.load(sys.stdin)['data']
s['pluginInstances']['gh-sales']={'id':'gh-sales','plugin':'github','label':'#sales','enabled':True,'config':{}}
open('/tmp/s2.json','w').write(json.dumps({'settings':s}))"
rpc save_settings "$(cat /tmp/s2.json)" >/dev/null
rpc set_plugin_secret '{"plugin":"gh-sales","key":"GH_SECRET","value":"DIFFERENT"}' >/dev/null
B='{"pull_request":{"title":"to sales","body":"x"}}'
ENG=$(python3 -c "import hmac,hashlib;print('sha256='+hmac.new(b's3cr3t-eng','''$B'''.encode(),hashlib.sha256).hexdigest())")
curl -s -o /dev/null -w "%{http_code}\n" -X POST localhost:4399/hooks/i/gh-sales/github -H "X-Hub-Signature-256: $ENG" -d "$B"   # EXPECT 401 (eng secret rejected on sales)
```

### 1.5 Per-instance outbound (URL + events filter + template override)
```bash
# local receiver that logs POSTs
cat > /tmp/recv.py <<'PY'
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n=int(self.headers.get('content-length',0)); b=self.rfile.read(n).decode()
        open('/tmp/hooks.log','a').write(f"{self.path} {b}\n")
        self.send_response(200); self.end_headers(); self.wfile.write(b'ok')
    def log_message(self,*a): pass
HTTPServer(('127.0.0.1',4500),H).serve_forever()
PY
: > /tmp/hooks.log; python3 /tmp/recv.py & sleep 0.5

# two slack instances: eng (default events) + sales (events=[done] only, custom template)
rpc get_settings '{}' | python3 -c "
import sys,json; s=json.load(sys.stdin)['data']; pi=s['pluginInstances']
pi['slack-eng']={'id':'slack-eng','plugin':'slack','label':'#eng','enabled':True,'config':{}}
pi['slack-sales']={'id':'slack-sales','plugin':'slack','label':'#sales','enabled':True,'config':{},'events':['done'],'template':'{\"text\":\"SALES {{card.title}}\"}'}
open('/tmp/s3.json','w').write(json.dumps({'settings':s}))"
rpc save_settings "$(cat /tmp/s3.json)" >/dev/null
rpc set_plugin_secret '{"plugin":"slack-eng","key":"WEBHOOK_URL","value":"http://127.0.0.1:4500/eng"}'  >/dev/null
rpc set_plugin_secret '{"plugin":"slack-sales","key":"WEBHOOK_URL","value":"http://127.0.0.1:4500/sales"}' >/dev/null

# trigger agent-result-changed by dropping a result file (no real agent needed)
CID=$(rpc add_card '{"input":{"title":"Ship it","status":"todo"}}' | python3 -c "import sys,json;print(json.load(sys.stdin)['data']['id'])")
mkdir -p "$SCRATCH/agent-results"
echo "{\"cardId\":\"$CID\",\"status\":\"awaiting_review\",\"result\":\"green\"}" > "$SCRATCH/agent-results/$CID.json"
sleep 1.5
cat /tmp/hooks.log
# EXPECT: only "/eng {...*Ship it* → awaiting_review...}"  (sales is done-only → silent)
```

### Teardown
```bash
lsof -ti tcp:4399 tcp:4500 | xargs kill 2>/dev/null
```

---

## Layer 2 — crypto / sync model (offline, no hub)

```bash
cd app/.claude/worktrees/e2e-sync
bun test src/lib/sync/crypto.test.ts   # sealed box, secret box, recovery derive, vault wrap/unwrap, rotation, no-plaintext-leak
bun test src/lib/sync/sync.test.ts     # LWW-per-instance merge, targeting, tombstones
```

---

## Layer 3 — Integrations UI in the browser (no Tauri, no login)

The web build gates non-Pro users behind login. Bypass for local testing with
`NEXT_PUBLIC_MYRA_TIER=pro`, and point the app's "local" connection at the
feature server with `NEXT_PUBLIC_MYRA_SERVER_URL`.

```bash
# 1) feature server on :4399 (clean dir + slack/github plugins) — see Layer 1 boot
SCRATCH=/tmp/myra-ui; rm -rf "$SCRATCH"; mkdir -p "$SCRATCH/plugins/slack" "$SCRATCH/plugins/github"
cp plugins/integrations/slack/manifest.json  "$SCRATCH/plugins/slack/manifest.json"
cp plugins/integrations/github/manifest.json "$SCRATCH/plugins/github/manifest.json"
MYRA_DIR="$SCRATCH" PORT=4399 server/target/debug/myra-server >/tmp/srv.log 2>&1 &

# 2) receiver on :4500 (Layer 1.5 recv.py)
: > /tmp/hooks.log; python3 /tmp/recv.py & 

# 3) dev app on :1420 (needs a REAL node_modules in the worktree, not a symlink)
cd app/.claude/worktrees/e2e-sync
[ -L node_modules ] && rm node_modules && bun install     # if it's a symlink
NEXT_PUBLIC_MYRA_SERVER_URL=http://127.0.0.1:4399 NEXT_PUBLIC_MYRA_TIER=pro bun run dev
```

Open http://localhost:1420 → Settings → **Integrations**, then:

- **3a** + New integration → slack → label `#eng-alerts`, secret URL
  `http://127.0.0.1:4500/eng` → Step 3 check **This device** → Deploy.
  Verify: `curl -s -X POST localhost:4399/rpc/get_settings -d '{}'` shows the
  instance; `rpc plugin_secret_status '{"plugin":"<id>"}'` → `["WEBHOOK_URL"]`.
- **3b** + New → slack → `#sales`, secret `.../sales`, Triggers = **Done only**,
  template `{"text":"SALES: {{card.title}}"}` → Deploy.
- **outbound E2E**: add a card, drop `agent-results/<cardId>.json` with
  `{"status":"awaiting_review",...}` (Layer 1.5) → `/tmp/hooks.log` shows only `/eng`.
- **3c** toggle `#sales` off → server `enabled=false`; click **Edit** on
  `#eng-alerts` → secret shows a **Set** badge.

This was automated end-to-end with Playwright; a tiny driver looks like:
```js
// node <file>.mjs  (run from inside the worktree so it resolves `playwright`)
import { chromium } from "playwright";
const b = await chromium.launch(); const p = await b.newPage();
await p.goto("http://localhost:1420/settings/", { waitUntil: "networkidle" });
await p.getByRole("tab", { name: /integrations/i }).click();
await p.getByRole("button", { name: /new integration/i }).first().click();
const d = p.getByRole("dialog");
await d.getByRole("button", { name: /^slack/i }).first().click();
await d.getByPlaceholder("e.g. #eng-alerts").fill("#eng-alerts");
await d.locator('input[type=password]').first().fill("http://127.0.0.1:4500/eng");
await d.getByRole("button", { name: /^next$/i }).click();
await d.getByRole("button", { name: /^deploy$/i }).click();
await b.close();
```

---

## Layer 4 — sync, headless protocol pieces

```bash
# app crypto two-device flow (wrap to 2 devices, recovery-only bootstrap, rotation)
cd app/.claude/worktrees/e2e-sync && bun test src/lib/sync/crypto.test.ts

# hub queue logic (fan-to-others, ack purge, bounded coalesce, revoke drops queue+wrapped)
cd hub/.claude/worktrees/e2e-sync/packages/hub && bun test src/cf/do-sync-store.test.ts
```

---

## NOT validated (needs real credentials / hardware)

| Area | Why it couldn't run here | What it needs |
|------|--------------------------|---------------|
| **Clerk sign-in** (web + desktop `myra://` deep-link) | No `NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY`; OAuth roundtrip can't be scripted | A Clerk instance + publishable key; click through hosted sign-in; on desktop confirm `myra://auth/callback` returns the session |
| **Sync UI panel** (Settings → Sync) | Needs the Tauri `keychain_*` commands (desktop only) + a signed-in session + a hub URL | `tauri:dev`, signed in, `NEXT_PUBLIC_MYRA_HUB_URL` set |
| **Hub sync endpoints over HTTP** (`/api/sync/*` through the Worker + session auth) | `wrangler dev` needs Node ≥22 (this box has 21); session JWT requires the hub secret | Node 22, `wrangler dev --local`, mint an HS256 session token with `MYRA_HUB_SECRET` |
| **Multi-device E2E** (device A edits → device B pulls/decrypts/applies; revoke→rotate) | 2 machines + a deployed/preview hub | 2 Tauri installs (or 2 profiles) + a reachable hub + the recovery-code flow |
| **Wizard → vault authoring** | Not built yet (Phase 2 gap #1) — the wizard still writes via Phase 1 direct fan-out, not into the synced set | Implement `bumpInstance`/`tombstone` → synced set on wizard save, then `syncNow` has real data |
| **Outbound via a real agent run** | Validated via a dropped result file instead of launching an agent binary | Configure an agent preset + launch a card; same `agent-result-changed` path |

### Full Layer-4 E2E setup (when you have Clerk + a hub)
1. Deploy the hub (`feature/e2e-sync`) to a preview Worker, or run `wrangler dev --local` on Node 22 with `MYRA_HUB_SECRET` in `.dev.vars`.
2. Launch the desktop app on machine A: `NEXT_PUBLIC_MYRA_HUB_URL=<hub> NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY=pk_... bun run tauri:dev`, sign in.
3. Settings → Sync → **Set up sync** → save the recovery code.
4. On machine B (or a 2nd profile): sign in → Sync → **Join with recovery code**.
5. Create/edit an instance on A → on B run **Sync now** → confirm it appears (once wizard→vault authoring lands).
6. **Revoke** B on A → confirm the vault rotates (new recovery code) and B can't decrypt new deltas.
7. Inspect hub storage → only ciphertext + public keys, never plaintext/vault key.
