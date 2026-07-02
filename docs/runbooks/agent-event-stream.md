# Agent event stream — unified JSONL lifecycle telemetry (PET-154)

One JSONL stream for **every agent role** (worker-243, reviewer-242, authoring loop 242, and the
Bucket-B **engine** tier on 242 — PET-184),
appended to `agent-evals/events.jsonl` in MinIO — the **same bucket** as the PET-135 verdict log.
This is the data layer for Mission Control v3 (PET-158 board, PET-155 viewer). Each agent emits
one row at each lifecycle point via `scripts/agent-event.sh`; read it back with `mc cat`.

## Schema

One object per line:

```json
{"ts":"","agent":"worker|reviewer|loop|engine","event":"","issue":"PET-n","pr":null,"detail":""}
```

`issue` and `pr` are nullable (`run_started` may have neither yet). `ts` is UTC ISO-8601, so the
stream is **time-ordered** by `ts`. `loop` is the Claude authoring loop (Platform/IaC); `engine`
is the Bucket-B engine tier (PET-184) authoring new effect kinds in the Co-latro repos — same
events, distinct lane.

## Events + who emits them

| Event | worker | reviewer | loop | engine | When |
|---|:--:|:--:|:--:|:--:|---|
| `run_started` | ✓ | ✓ | ✓ | ✓ | iteration begins (before picking) |
| `issue_picked` | ✓ | ✓ | ✓ | ✓ | after claiming / selecting the issue→PR |
| `pr_opened` | ✓ |  | ✓ | ✓ | a PR is opened |
| `verdict_posted` |  | ✓ |  |  | reviewer posts approve/changes |
| `changes_requested` |  | ✓ |  |  | reviewer kicks a PR back |
| `stalled` |  |  | ✓ | ✓ | stall sweep releases a stale claim (PET-147) |
| `escalated_needs_human` | ✓ | ✓ | ✓ | ✓ | an issue is set `needs-human` |
| `run_exited` | ✓ | ✓ | ✓ | ✓ | iteration ends (clean or aborted) |

> The `engine` lifecycle in `events.jsonl` is distinct from the fleet page's per-lane
> `engine-runs.jsonl` run-log (PET-187 / schema TBD under PET-184) — the fleet view reads the
> per-lane logs, this stream feeds the PET-155 lifecycle viewer.

## How each agent emits

`agent-event.sh` is a one-line call folded into each role's existing standing prompt (there is no
`run-loop.sh`). Examples:

```sh
scripts/agent-event.sh --agent loop --event run_started
scripts/agent-event.sh --agent loop --event issue_picked --issue PET-42
scripts/agent-event.sh --agent loop --event pr_opened --issue PET-42 --pr 64
scripts/agent-event.sh --agent reviewer --event verdict_posted --issue PET-42 --pr 64 --detail approve
scripts/agent-event.sh --agent engine --event issue_picked --issue PET-208
scripts/agent-event.sh --agent loop --event escalated_needs_human --issue PET-144 --detail "PET-104 conflict"
scripts/agent-event.sh --agent loop --event run_exited --issue PET-42 --pr 64
```

`--dry-run` prints the row without uploading (no `mc` needed) — use it to eyeball before wiring.
Add these calls to:
- **Authoring loop** — at run start, after the claim (`issue_picked`), after `gh pr create`
  (`pr_opened`), on a stall release ([loop-stall-detection.md](loop-stall-detection.md)) and any
  `needs-human` escalation, and at exit.
- **Reviewer** — at run start, per PR (`verdict_posted` / `changes_requested`), and exit
  ([reviewer-loop.md](reviewer-loop.md), step after posting the verdict).
- **Worker** — at run start, `issue_picked`, `pr_opened`, escalation, exit (Worker Operations doc).
- **Engine** (Bucket-B tier, PET-184) — same lifecycle as the authoring loop, with `--agent engine`.

### Crash-safe bracketing (run_started / run_exited)

`run_exited` emitted at the model's discretion is lost if the run crashes mid-way. For the Claude
loops that run `cc` from a bare prompt (authoring + engine), wrap the invocation in
`scripts/agent-run-events.sh`, which brackets the command with `run_started` and a `run_exited`
fired from an **EXIT trap** (so it lands even on crash/kill — the worker harness does the same):

```sh
scripts/agent-run-events.sh --agent engine --issue PET-208 -- cc --model claude-opus-4-8 -p "$PROMPT"
```

The wrapped agent still emits `issue_picked` / `pr_opened` itself from inside the run (it alone
knows the issue#/PR#). Wiring this into the on-242 loop launch is an operator step.

The verdict log (PET-135) and stall detection (PET-147) already produce most of these moments;
this just standardizes them into one stream.

## Reading the stream

```sh
mc cat homelab/agent-evals/events.jsonl                      # whole stream
mc cat homelab/agent-evals/events.jsonl | tail -20           # latest
mc cat homelab/agent-evals/events.jsonl | python3 -c \
  'import json,sys; [print(r["ts"], r["agent"], r["event"], r.get("issue")) for r in map(json.loads, sys.stdin)]'
```

(`jq` isn't on the loop host — use `python3`.)

## Manual steps for Pedro

Same prerequisites as the verdict log — **shared, do once**:
1. **Bucket** (the loop can't create it — no mutation creds): `mc mb homelab/agent-evals` +
   `mc version enable homelab/agent-evals` (already required by PET-135; the event stream reuses it).
2. **`mc` alias on 242** from Vault by path (never inline): `kv/services/agent-loop`
   (`mc_access_key`/`mc_secret_key`), bucket-scoped svcacct for `agent-evals`. See
   [reviewer-loop.md](reviewer-loop.md) §"Pedro's one-time setup".
3. **`mc` binary** on each agent host — installed by `roles/agent-loop` (`agent_loop_install_mc`).

No secrets in the repo: `agent-event.sh` reads creds only from the preconfigured `mc` alias.

## Acceptance

One full worker run + one reviewer pass produce a correctly time-ordered event sequence readable
via `mc cat` — e.g. `loop run_started → issue_picked → pr_opened → run_exited` interleaved with
`reviewer run_started → verdict_posted → run_exited`, ordered by `ts`.
