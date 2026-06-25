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
| **Reviewer** | `verdicts.jsonl` | `scripts/reviewer/reviewer-log-verdict.sh` (PET-135) | `{ts, issue, pr, worker_model, harness, worker_tests:pass\|fail, claude_verdict:approve\|changes, claude_findings:[], pedro_verdict:merge\|kickback\|"", round_trips, tokens, wall_s}` |
| **Worker** | `worker-runs.jsonl` | `scripts/worker/worker-run.sh` (worker-loop.md) | `{ts, issue, repo, branch, pr:int\|null, worker_model, harness, tests:pass\|fail\|skipped\|none, guard:ok\|blocked, tokens, wall_s, head_sha}` |
| **Engine** | `engine-runs.jsonl` | *(none yet — forward-compat, PET-184)* | TBD → lane shows an empty-state until the file exists |

### Co-latro filter (made obvious in `app.js`)

`CO_LATRO_REPOS = ['co-latro-backend', 'co-latro-frontend']`.

- **Worker / Engine** rows carry an explicit `repo` → filtered directly on it.
- **Reviewer verdicts have no `repo`** (the reviewer logs only the PR *number* + the `PET-n`
  key). So a verdict is treated as Co-latro by **joining on its PET issue key** to the repo seen
  in the worker/engine rows. A verdict whose repo can't be confirmed is **hidden but counted**
  (shown in a banner — never silently dropped). The join also resolves the GitHub PR link for
  verdict rows; it falls back to `DEFAULT_REPO` (`co-latro-backend`) only for the link.

## Access — restricted to `pedro`

Two layers. **The real boundary is layer 1 (Authentik); this page cannot be a security boundary.**

1. **Authentik (Manual, Pedro — the boundary):** bind the application/provider to user `pedro`
   only (policy `user == pedro`), mirroring the `vault.pdlab.dev` gate (PET-38). Every other
   authenticated user is 403'd upstream.
2. **In-page (built here — UX + defense-in-depth):** on load the page calls
   `fetch('/whoami', {credentials:'same-origin'})`, expecting `{"username": "..."}` (the proxy
   echoes `X-authentik-username` — a Manual step). `ALLOWED_USER = 'pedro'`. If the fetch fails
   **or** `username !== ALLOWED_USER`, it renders a **"Not authorized"** locked state and loads
   **zero** fleet data.

## Behavior

- **Three lanes**, each with a *latest* card (most recent run) + a *history* table (newest first):
  PET-id → Linear, PR → GitHub, `worker_model`/`harness`, test result, verdict, `pedro_verdict`,
  round-trips, age. Cells a lane doesn't have render as `—`.
- **Roll-up (Co-latro only):** worker runs + success rate, reviewer approve/changes, Pedro
  merge/kickback/pending, and the round-trip distribution.
- **Auto-refresh** every ~20s (pauses when the tab is hidden); shows *last updated* and a
  per-file empty/error banner. Any file missing / empty / unreachable → that lane shows an
  empty/error state, never a crash.

## Manual steps for Pedro (live infra / SSO / hosting — not done here)

Authoring only. **No** Authentik/SSO changes, **no** MinIO bucket-policy changes, **no** Vault
reads, **no** secrets embedded. To deploy:

1. **Authentik single-user gate** — bind this app to user `pedro` (layer 1 above).
2. **`/whoami` endpoint** on the Authentik-fronted reverse proxy — echo `X-authentik-username`
   (and `-email`) as JSON `{"username": "..."}`.
3. **Host the static files** via the MinIO static-site-behind-Authentik pattern (PET-87) + a
   route from the URL factory (PET-35).
4. **Expose `agent-evals/*.jsonl` same-origin** behind the same auth (a `/agent-evals` proxy path
   or a read-only bucket policy) so the page fetches with no creds. Service-account / Vault paths
   by **name only** (`kv/services/agent-loop`) — never embed a key.

If a future requirement seems to need a server/backend, that's the wrong design for this page —
stop and reconsider, don't add one here.
