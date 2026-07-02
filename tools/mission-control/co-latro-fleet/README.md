# Mission Control — Co-latro fleet activity view (PET-187)

A single **read-only static page** that shows what the **Co-latro agent fleet** is doing —
**Worker · Reviewer · Engine** — by reading the `agent-evals` JSONL eval logs in MinIO over plain
`fetch()`. No backend, no build step, no framework. Sibling of the PET-158 PR board
([`../index.html`](../index.html)); it reuses that artifact's theme. It **never writes anything**
— only GET requests.

This is the near-term, Co-latro-scoped cut of the read-only dashboard idea (PET-155), built now
off the **existing per-role eval files** so it doesn't wait on the unified event stream (PET-154).

## Files

```
co-latro-fleet/
  index.html        structure (loads app.css + app.js)
  app.css           theme — mirrors PET-158's GitHub-dark tokens / monospace
  app.js            fetch + JSONL parse + Co-latro filter + render + auto-refresh
  fixtures/         local-dev sample data (verdicts / worker-runs / engine-runs .jsonl)
  README.md         this file
```

## Run it locally

The page fetches local files, so serve the folder (browsers block `file://` fetches of siblings):

```sh
cd tools/mission-control/co-latro-fleet
python3 -m http.server 8187      # or: bunx serve .
# open http://localhost:8187/index.html?dev=1
```

`?dev=1` (also auto-on for `file://`) makes the page read `./fixtures` and **skip the identity
gate** so the three lanes render standalone. Dev convenience only — see *Access*.

## Data contract (read-only, same-origin)

Source: MinIO `.221`, bucket `agent-evals` (versioned). In production the page reads them from a
**same-origin relative path** behind the Authentik proxy: `DATA_BASE = '/agent-evals'` (so
`/agent-evals/verdicts.jsonl`, etc.). No CORS, no credentials, no tokens in the page. Unknown
fields are ignored and missing fields tolerated; one malformed line never crashes a lane.

| Lane | File | Writer | Schema (verified against the writer) |
|---|---|---|---|
| **Reviewer** | `verdicts.jsonl` | `scripts/reviewer/reviewer-log-verdict.sh` (PET-135) | `{ts, issue, pr, worker_model, harness, reviewer_model, worker_tests:pass\|fail, claude_verdict:approve\|changes, claude_findings:[], pedro_verdict:merge\|kickback\|"", round_trips, tokens, wall_s}` — `worker_model`/`harness` = the PR under review; `reviewer_model` (PET-199) = the model that decided the verdict (the lane's `model` column shows this, reviewed worker model/harness in its tooltip) |
| **Worker** | `worker-runs.jsonl` | `scripts/worker/worker-run.sh` (worker-loop.md) | `{ts, issue, repo, branch, pr:int\|null, worker_model, harness, tests:pass\|fail\|skipped\|none, guard:ok\|blocked, tokens, wall_s, head_sha}` |
| **Engine** | `engine-runs.jsonl` | `scripts/engine/engine-run.sh` (engine-loop.md, PET-184) | `{ts, issue, repo, branch, pr:int\|null, engine_model, harness:claude-code-headless, tests:pass\|fail\|skipped\|none, guard:green\|red\|n/a (the gate verdict), tokens, wall_s, head_sha}` — the lane's `model` column shows `engine_model`; a cap-paused run exits before logging (no row), so a red row means the gate failed, not that the engine gave up |
| **Live views** | `events.jsonl` | `scripts/agent-event.sh` (PET-154) | `{ts, agent:worker\|reviewer\|loop\|engine, event, issue:"PET-n"\|null, pr:int\|null, detail}` — the unified lifecycle stream. events: `run_started · issue_picked · pr_opened · verdict_posted · changes_requested · stalled · escalated_needs_human · run_exited`. **Carries no `repo`** (unlike the run logs), so status cards are fleet-wide and the pipeline joins on the PET key. Missing/empty → the live views degrade to idle + a runs-only pipeline, never a crash |

### Co-latro filter (made obvious in `app.js`)

`CO_LATRO_REPOS = ['co-latro-backend', 'co-latro-frontend']`.

- **Worker / Engine** rows carry an explicit `repo` → filtered directly on it.
- **Reviewer verdicts have no `repo`** (the reviewer logs only the PR *number* + the `PET-n`
  key). So a verdict is treated as Co-latro by **joining on its PET issue key** to the repo seen
  in the worker/engine rows. A verdict whose repo can't be confirmed is **hidden but counted**
  (shown in a banner — never silently dropped). The join also resolves the GitHub PR link for
  verdict rows; it falls back to `DEFAULT_REPO` (`co-latro-backend`) only for the link.

## Access — restricted to `pedro`

**The real boundary is Cloudflare Access at the edge — this static page cannot be one.**

1. **Cloudflare Access (the boundary):** `fleet.pdlab.dev` is fronted by a Cloudflare Access
   application whose policy allows only `pedelgadillo@gmail.com` (One-Time PIN login); every
   other identity is blocked at the edge before the origin is reached. Codified in IaC — see
   [`docs/runbooks/fleet-activity-view.md`](../../../docs/runbooks/fleet-activity-view.md).
2. **In-page (UX + defense-in-depth):** on load the page calls `fetch('/whoami')`, expects
   `{"username": "..."}`, and renders a **"Not authorized"** locked state unless it equals
   `ALLOWED_USER = 'pedro'`. In the live deployment nginx returns a static `{"username":"pedro"}`
   (reachable only *after* Access lets you through), so this layer is cosmetic — Access is what
   actually gates. The page stays auth-agnostic: front it with Authentik forward-auth instead and
   `/whoami` can echo the real `X-authentik-username`.

## Live views (PET-220) — built from `events.jsonl`

Three views render **what's happening now** from the unified lifecycle stream, above the ledger:

1. **Live status cards** — one per Co-latro fleet agent (worker · engine · reviewer). *(The IaC
   `loop` agent isn't instrumented and isn't Co-latro, so it has no card — PET-221.)* State is
   **inferred from the last event**: an open run (a `run_started`/`issue_picked` with no later `run_exited`)
   ⇒ **running** (current issue + time-in-state); a `stalled`/`escalated_needs_human` last event ⇒
   **stalled / needs-human** (red alert); otherwise **idle** (time since last activity). The `model`
   is read from the latest matching run/verdict row (events don't carry it). **Limitation:** there
   is **no heartbeat** — we stay no-backend, so "running" means *last event was a start*, not a live
   liveness probe; a crashed loop that never emitted `run_exited` reads as running until the next
   event. Age is your tell. This is the "is the loop hung?" glance.
2. **Pipeline (kanban)** — each recently-active Co-latro issue sits in the furthest stage it has
   reached across **Todo → authoring → gate → PR → review → merge**, joining `events.jsonl` (author
   lifecycle) with `verdicts.jsonl` (`claude_verdict`/`pedro_verdict`) and the run logs on the PET
   key. Chips are coloured green (merged) / blue (in-flight) / yellow (changes or gate-fail) / red
   (stalled). `loop` (IaC) events are excluded; a non-Co-latro issue is dropped. The "where is
   PET-N stuck?" view.
3. **Trends** — `ts` bucketed by day: worker pass-rate, engine gate-green rate, reviewer approve
   rate (each with a sparkline), engine tokens/day, and the round-trip distribution. **Cost data is
   thin** — worker & reviewer log `tokens:0` today, only the engine logs real tokens; the tokens
   sparkline reflects only what exists.

## Behavior

- **Three lanes**, each with a *latest* card (most recent run) + a *history* table (newest first):
  PET-id → Linear, PR → GitHub, `model`/`harness` (the lane agent's own — reviewer rows show
  `reviewer_model`, with the reviewed worker model/harness in the cell tooltip), test result,
  verdict, `pedro_verdict`, round-trips, age. Cells a lane doesn't have render as `—`.
- **Roll-up (Co-latro only):** worker runs + success rate, reviewer approve/changes, Pedro
  merge/kickback/pending, and the round-trip distribution.
- **Auto-refresh** every ~20s (pauses when the tab is hidden); shows *last updated* and a
  per-file empty/error banner. Any file missing / empty / unreachable → that lane shows an
  empty/error state, never a crash.

## Deploying it live

The live deployment (Cloudflare Access edge gate + nginx origin on LXC 242) is codified in IaC —
see the runbook [`docs/runbooks/fleet-activity-view.md`](../../../docs/runbooks/fleet-activity-view.md)
for the full ordered procedure. In short:

- **Terraform** (`environments/homelab/cloudflare-routes.tf`): the `fleet.pdlab.dev` route with
  `access = true` + `access_emails = ["pedelgadillo@gmail.com"]` → Cloudflare creates the proxied
  CNAME, the tunnel ingress, and the Access application/policy on merge (apply-on-merge).
- **Ansible** (`ansible/playbooks/configure-fleet.yml`): nginx on `242:8090` serving these files +
  a same-origin `mc mirror` of the `agent-evals` bucket + the static `/whoami`. **`events.jsonl`
  needs no mirror change** — the mirror is a *whole-bucket* `mc mirror homelab/agent-evals`, so the
  stream is served the moment `scripts/agent-event.sh` writes it; only `index.html`/`app.css`/`app.js`
  (the `fleet_static_files` list) are pushed by the copy task, and this change touches only those.
- **Pedro's one-time prerequisites** (Cloudflare dashboard, *before* merge): a Zero Trust org /
  team domain exists, One-Time PIN login is enabled, and the API token has *Access: Apps and
  Policies → Edit*. Then complete the OTP login (the code is emailed to you).

Secrets stay in Vault (`kv/services/agent-loop`, `kv/iac/cloudflare`), referenced by name — never
embedded. The page reads only same-origin relative paths; no creds, no backend. If a future
requirement seems to need a server/backend, that's the wrong design for this page.
