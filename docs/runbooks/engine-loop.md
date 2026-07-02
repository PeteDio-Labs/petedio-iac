# Engine loop — agent-loop-242 (PET-184)

The **third fleet tier**. The worker (local 7B) adds additive catalog entries that *reuse* an
existing effect `kind`; the **engine** (Claude Code, Sonnet-tier, headless) writes the *new*
`kind` — its handler in the scoring/run engine + a tested exemplar entry + registering the kind
into the property generators — which then flips that whole cluster to Bucket-A for the worker.
The reviewer (Opus, **stronger**) and Pedro are the downstream gates; **the engine never merges.**

It is the **lowest-priority** consumer of the one shared Claude **Max** quota
(`Pedro > reviewer > engine`), so it runs **boxed and yielding**.

## Pieces (all in `scripts/engine/`)

| Script | Role |
|---|---|
| `engine-run.sh` | author ONE Bucket-B kind: clean/resume clone → boxed `claude -p` → **independent gate** → branch-guarded push + PR as `petedio-engine[bot]` → `engine-runs.jsonl`. |
| `engine-gate.sh` | the "can't finish red" gate: `tsc --noEmit` → `bun test` → hardened property re-run. Wired as a Claude **Stop hook** (exit 2 blocks the engine ending red) **and** re-run by the harness as ground truth. |
| `engine-loop.sh` | one scheduled **tick**: pause/off-hours/reviewer guards + cc-slot flock → pick one unit (resume before new) → `engine-run.sh`. Also `enqueue` / `status` subcommands. |
| `engine-candidates.sh` | Bucket-B poll (Todo + `engine-ok`), thin wrapper over `worker-candidates.sh`. |
| `engine-mint-token.sh` | mint the `petedio-engine[bot]` token (→ `agent-mint-token.sh engine`). |

## The boxed-authoring safety model

The engine is a *capable* agent, so unlike the worker it drives its own edits + local commits —
but it is **boxed** so a bad run can't do damage:

- **Throwaway per-task clone** (`~/engine/work/PET-<n>`), never a human tree.
- **Tool allowlist**: edit/read/test/**local** git only. No `git push`, no `gh`, no arbitrary
  bash. `GH_TOKEN` is **not in the agent's env** — it's minted only for the harness's push/PR
  step. The engine **structurally cannot** push, open a PR, or merge.
- **Stop-hook gate** — it cannot declare "done" while the gate is red.
- **`--max-turns` + `timeout`** bound the cost of an unfixable red.
- **Independent gate** — the harness re-runs `engine-gate.sh` as ground truth before it pushes;
  a green PR was verified by the harness, not just claimed by the agent.
- **Least-privilege token** (contents + PR write, **no merge**) + the reviewer + Pedro downstream.

## Prerequisites (one-time)

1. **Identity — `petedio-engine[bot]` (Pedro).** Create a THIRD GitHub App mirroring PET-176
   (contents:write + pull_requests:write, **no merge**), install it on `co-latro-backend`, and
   seed Vault `kv/services/agent-loop`:
   `engine_app_id`, `engine_installation_id`, `engine_app_pem`. It **must** be a different App id
   than `worker_app_id`/`reviewer_app_id` (identical ids collapse identities and re-arm GitHub's
   self-review block). Verify: `GH_TOKEN="$(scripts/engine/engine-mint-token.sh)" gh api user`.
2. **Model id.** PET-184 pins `claude-sonnet-5`. Validate on the host once:
   `claude --model claude-sonnet-5 -p ok`. If that build isn't live, set the current Sonnet-tier
   id in `agent_loop_engine_model` (Ansible) / `ENGINE_MODEL` — a one-var change. Never let the
   engine match/exceed the reviewer's Opus.
3. **Host bring-up.** `ansible-playbook playbooks/configure-agent-loop.yml` creates
   `~/engine/{work,state,queue}` and (when `agent_loop_engine_timer_enabled: true`) installs the
   `engine-loop.timer`. The loop user must already have `claude` logged in (Max plan, no API key).

## Operation — the S0 → S1 supervision ramp

**S0 (start here — Pedro-supervised, by hand).** Timer OFF. Pick a Bucket-B issue (biggest
cluster first, per PET-184 Phase 2), read its spec via the Linear MCP, and run one task:

```sh
ssh agent@192.168.50.242
cd ~/work/petedio/iac
echo "<the issue spec>" | scripts/engine/engine-run.sh PET-<n> \
  --repo PeteDio-Labs/co-latro-backend --slug <branch-slug> --spec -
# watch the gate output; it opens a PR as petedio-engine[bot] (draft if the gate is red).
```

**S1 (unattended, off-hours).** Once a few S0 runs look good, graduate: set
`agent_loop_engine_timer_enabled: true` and re-run the playbook. Now the **interactive side
enqueues** curated work and the **timer drains** it (resume before new), only during the
off-hours window, only when the cc-slot is free and no reviewer/pause sentinel is set:

```sh
# enqueue a curated task (interactive Claude, via MCP, does the picking + spec):
scripts/engine/engine-loop.sh enqueue PET-<n> --repo PeteDio-Labs/co-latro-backend \
  --slug <slug> --spec-file <spec.md>
scripts/engine/engine-loop.sh status     # queued + in-flight checkpoint state
```

**Logic PRs stay human-merge, always.** S2 (reduced supervision) is a later ramp gated on the
eval pass-rate bar — never full auto-merge for new-kind logic.

## Yield & checkpoint controls

- **Pause / "Pedro active":** `touch ~/engine/PAUSED` → every tick parks. `rm` to resume.
- **Reviewer preempt:** `~/engine/REVIEWER_ACTIVE` present → the tick yields (reviewer outranks).
- **cc-slot:** `ENGINE_SLOT_LOCK` (`/run/lock/cc-slot`) — one automated Claude Code session at a
  time on 242. A busy slot → the tick exits immediately.
- **Checkpoint / resume (0e):** git is the checkpoint — the engine WIP-commits each coherent,
  *compiling* step; `~/engine/state/PET-<n>.json` records the phase. A later tick resumes the
  branch instead of resetting (`--fresh` forces a clean-main restart).
- **Cap-hit:** on a usage-cap the run commits WIP, records the reset in the sidecar, and exits
  **4** (resumable). The loop backs off and resumes the same task after the reset. A transient
  "overloaded"/rate-limit is distinguished from a real usage cap.

## Eval log

`engine-run.sh` appends one row per run to MinIO `agent-evals/engine-runs.jsonl`:
`{ts, issue, repo, branch, pr, engine_model, harness, tests, guard, tokens, wall_s, head_sha}`
(`guard` = the gate verdict `green|red|n/a`). It feeds the PET-187 fleet view's **Engine** lane
and the autonomy pass-rate bar. A cap-paused run exits *before* logging (no row), so a `red` row
means the gate failed — not that the engine gave up. Lifecycle events go to the shared
`events.jsonl` via `agent-event.sh --agent engine` (do **not** emit either off-loop, PET-212).

## Hard rules (mirror the worker's)

The engine NEVER merges, never reviews, never touches Vault writes / TF state / live hosts, and
only ever force-pushes its OWN `pet-*` branch. Resumable unit = **one kind per task**.
