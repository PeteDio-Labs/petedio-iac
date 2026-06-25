# Worker loop — agent-worker (PET-179)

The **worker half** of the two-agent system. A small, cheap local model (`qwen3:8b` served
by Ollama at `http://192.168.50.12:11434`, OpenAI-compatible `/v1`) drives the
[OpenCode](https://opencode.ai) harness on the loop host to AUTHOR one Co-latro issue at a
time: it picks a `worker-ok` + Todo issue, branches `pet-<n>-<slug>` off clean `main`,
implements the change, runs the **additive guardrail** + `bun test`, pushes, and opens a PR
(**draft when tests are red**). It **never merges, never reviews, never mutates Linear
status, never touches Vault writes / TF state / live hosts.** The reviewer loop
(`docs/runbooks/reviewer-loop.md`) judges the PR; Pedro merges.

Authoritative protocol: the Linear docs **[Worker Operations — agent-worker]** and the
shared **[Agent Loop Operations]** (hard rules apply verbatim). This runbook is the on-host
operational companion — the scripts, the standing prompt, and Pedro's one-time setup.

## Scripts (`scripts/worker/`)

| Script | Role | Mutates? |
|---|---|---|
| `worker-candidates.sh` | List `worker-ok` + **Todo** Co-latro issues the worker may pick, annotated `{key,title,repo,branch_slug}` (JSON). Uses the Linear GraphQL API **if** a token is reachable (env `LINEAR_API_KEY` or Vault `kv/services/linear:api_key`); else prints `[]` and tells Claude to enumerate via the Linear MCP. | No (read-only) |
| `worker-run.sh PET-<n> --repo <owner/repo> --spec-file <f>` | The core wrapper: reset clean `main` → write the prompt → run `opencode run --pure -m ollama/qwen3:8b` → guardrail → `bun install`+`bun test` → push **own `pet-*` branch** (force-with-lease) → open **draft PR if tests fail / normal PR if green** → emit lifecycle events → append the worker eval row. | Pushes its own branch, opens a PR, appends to MinIO. **Never merges.** |
| `worker-guard-additive.sh` | The guardrail. Reads a unified diff; **exit 2 / "blocked"** when the net count of catalog entries (`id:` rows) or test cases (`test(`/`it(`) **DROPS** — the 8B overwrite-not-append failure. `--self-test` feeds a synthetic delete-not-append diff and asserts it's caught. `WORKER_GUARD_ALLOW_SHRINK=1` for a genuinely subtractive issue. | No (read-only check) |
| `templates/worker-prompt.md.tmpl` | Harness task-prompt skeleton (the "ADD, never delete" framing). | — |
| `templates/pr-body.md.tmpl` | Worker PR-body skeleton (tests result, guardrail verdict, head). | — |

The scripts do what shell does well (poll, reset, run the harness, count the diff, test,
push, log). The **judgment** — which issue, reading the issue body into a task spec, deciding
when a round-trip is exhausted — is Claude's (via the Linear MCP), driven by the standing
prompt below. (Same split as the reviewer: a shell script can't reason over a Linear issue.)

## Why the worker needs Linear differently than the reviewer

The reviewer's candidates are open **PRs**, which `gh` sees directly — so its candidate
script is fully mechanical. The worker's candidates are **Linear issues** (`worker-ok` +
Todo), which live ONLY in Linear, and the homelab still has **no provisioned Linear API
token** (`kv/services/linear`, field `api_key`, is the documented-but-unfilled path
PET-145/147 + mission-control + loop-stall-detection all reference). So `worker-candidates.sh`
uses the GraphQL API opportunistically when a token exists and otherwise delegates the
enumeration to Claude's Linear MCP — the same precedent the reviewer/stall-detection runbooks
set. When Pedro provisions `kv/services/linear:api_key`, the script self-serves it via the
Vault Agent token and the poll becomes fully headless (no MCP step).

## The worker standing prompt

There is no `run-loop.sh` (same as the reviewer/authoring loops). Run `cc` (Claude Code) as
the worker user in a tmux session and give it this prompt. Claude orchestrates; the 8B model
only ever runs *inside* `worker-run.sh` as the authoring harness — never as the orchestrator.

```
You are the ORCHESTRATOR of the WORKER half of the two-agent loop on agent-worker. Read the
Linear docs "Worker Operations — agent-worker" and "Agent Loop Operations" in full first —
the hard rules bind you (no merge, no review, no apply/import/state, no SSH to live hosts,
no Vault writes, never change another role's Linear status, only ever push your OWN pet-*
branch). The 8B model AUTHORS; you orchestrate + supply the spec.

Each iteration:
1. Run `scripts/worker/worker-candidates.sh`. If it returns issues, use them; if it returns
   `[]` with the no-token note, enumerate `worker-ok` + Todo Co-latro issues via the Linear
   MCP yourself. Pick the OLDEST unworked one. Skip anything `needs-human`.
2. Move it to In Progress (your own claim — within the worker's status authority) and read
   the FULL issue body. Write the task spec to a file (the issue body, plus the additive
   framing from templates/worker-prompt.md.tmpl).
3. Run the wrapper:
     scripts/worker/worker-run.sh PET-<n> --repo <owner/repo> --spec-file <spec> --slug <linear-branch-slug>
   It resets clean main, runs the 8B harness, runs the GUARDRAIL (a delete-not-append diff
   is BLOCKED — exit 3), runs bun test, pushes your pet-* branch, and opens a DRAFT PR if
   tests fail / a normal PR if green. Read its JSON summary.
4. If the guardrail BLOCKED (exit 3): the 8B model overwrote-instead-of-appended. Re-run the
   wrapper with a sharper "ADD only, do not touch existing entries" spec. Max 2 such round-
   trips, then post a `needs-human` comment and stop on that issue.
5. If tests fail: the PR is opened as a DRAFT. Leave it for the reviewer/round-trip; do NOT
   merge, do NOT mark Done.
6. Move the issue to In Review (your claim's natural next state). Report the PR + result on
   the issue. One issue per iteration. If anything is ambiguous or risky, comment and stop.
```

## Pedro's one-time setup (Manual steps)

These are operator-only — the loop is author-only and never does them.

1. **Ollama model on `.12`** — `qwen3:8b` pulled and served:
   ```sh
   curl http://192.168.50.12:11434/api/version          # Ollama answering
   curl http://192.168.50.12:11434/v1/models | grep qwen3   # the model is loaded
   ```
2. **OpenCode on the worker host**, pointed at Ollama's OpenAI-compatible endpoint
   (`http://192.168.50.12:11434/v1`) with the `ollama/qwen3:8b` provider/model configured.
   Verify: `opencode run --pure -m ollama/qwen3:8b "say hi"` returns a completion.
   > NOTE (PET-179): the spec's invocation is `opencode run --pure …`. Confirm the installed
   > OpenCode build accepts `--pure` and `--format json`; if a build renames a flag, override
   > the base invocation with `WORKER_OPENCODE_CMD` (and keep token capture via `--format
   > json`). The repo's local-dev OpenCode (1.1.x) had no documented `--pure`; the loop host's
   > build is authoritative.
3. **`bun` on the host** + the **local Postgres** the Co-latro suite needs (PET-178) — both
   installed by `roles/agent-loop`; the suite is GREEN at baseline, so a `bun test` failure
   in a worker run is REAL, not an env gap.
4. **GitHub identity** — the worker authors as the **`petedio-worker[bot]`** GitHub App
   (PET-176), not Pedro's PAT. `worker-run.sh` mints a 1-hour installation token on demand
   via `scripts/worker/worker-mint-token.sh` (push + open-PR scope, **structurally cannot
   merge**); the App PEM lives in Vault `kv/services/agent-loop:worker_app_pem`, served via
   the Vault Agent token on disk. Nothing long-lived on the host; never inline the token.
5. **`mc` alias + eval bucket** — same as the reviewer (`docs/runbooks/reviewer-loop.md`):
   the worker appends its run rows to `agent-evals/worker-runs.jsonl` (a sibling of the
   reviewer's `verdicts.jsonl`) and emits lifecycle events to `agent-evals/events.jsonl`
   (PET-154) via the same alias.
6. **(Optional) Linear token** — provision `kv/services/linear:api_key` to make
   `worker-candidates.sh` fully headless (shared with PET-145/147). Until then the MCP
   enumeration in the standing prompt covers it.
7. **Start the loop**: attach the tmux session in the worker's Co-latro clone, run `cc`,
   paste the standing prompt. Run the first iterations **supervised**.

## Worker run-row schema (`agent-evals/worker-runs.jsonl`)

One JSON object per line — the worker-authored eval set (sibling of the reviewer's
`verdicts.jsonl`):

```json
{"ts":"","issue":"PET-n","repo":"","branch":"pet-n-slug","pr":<int|null>,"worker_model":"","harness":"","tests":"pass|fail|skipped|none","guard":"ok|blocked","tokens":0,"wall_s":0,"head_sha":""}
```

Together with the reviewer's `verdicts.jsonl` and the PET-154 `events.jsonl` stream, this is
the labeled dataset for worker success rate, guardrail hit rate, and tokens/wall per issue.

## Hard limits (restated)

- Author + push (own `pet-*` branch) + open a PR + append-to-log only. **No** merges, no
  reviews, no commits to a human's branch, no `apply`/`import`/state, no SSH to live hosts,
  no Vault writes, and never change another role's Linear status.
- **The additive guardrail is mandatory** — a worker run that drops catalog entries or test
  cases is BLOCKED before the PR is opened (`worker-guard-additive.sh`, exit 3 in the
  wrapper). Override only for a genuinely subtractive issue (`WORKER_GUARD_ALLOW_SHRINK=1`).
- **Draft the PR when tests fail** — a red worker PR must never look mergeable.
- Max **2 round-trips** on a blocked/failed issue, then a `needs-human` comment and stop.
- Verify any merge claim via `gh pr view --json mergedAt` (use `scripts/pr-merge-status.sh`)
  before asserting it (PET-146) — though the worker never merges, so this is only for reports.

[Worker Operations — agent-worker]: https://linear.app/petedillo/team/PET
[Agent Loop Operations]: https://linear.app/petedillo/document/agent-loop-operations-living-doc-agent-reads-every-run-bf14d40272b9
