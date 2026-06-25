# `scripts/worker/` — the worker loop (PET-179)

Helper scripts for the **worker half** of the two-agent system. A cheap local model
(`qwen3:8b` via Ollama, driven by the OpenCode harness) AUTHORS one Co-latro issue at a
time; these scripts gather the candidates, run the harness safely, and guard against its
known failure mode. The **orchestration** — picking the issue, reading its body into a task
spec, the round-trip cap — is Claude's (via the Linear MCP), per the standing prompt.

Full operational guide, the standing prompt, and Pedro's one-time setup:
**[`docs/runbooks/worker-loop.md`](../../docs/runbooks/worker-loop.md)**.

| Script | What it does |
|---|---|
| `worker-candidates.sh` | List `worker-ok` + **Todo** Co-latro issues the worker may pick (JSON). Linear GraphQL if a token is reachable; else `[]` + a note to enumerate via the Linear MCP (no Linear token is provisioned yet — PET-145/147). |
| `worker-run.sh PET-<n> --repo <owner/repo> --spec-file <f>` | Reset clean `main` → run `opencode run --pure -m ollama/qwen3:8b` → **guardrail** → `bun install`+`bun test` → push own `pet-*` branch → open **draft PR if tests fail / normal PR if green** → emit events → append the eval row. |
| `worker-guard-additive.sh` | The "green-but-wrong" guard. Exit 2 when a diff DROPS catalog entries / test cases (the 8B overwrite-not-append failure). `--self-test` proves it catches a synthetic delete-not-append diff. |
| `templates/worker-prompt.md.tmpl` | Harness task-prompt skeleton (additive framing). |
| `templates/pr-body.md.tmpl` | Worker PR-body skeleton. |

**Hard rules:** these scripts never merge, never review, never push to a human's branch
(only the worker's own `pet-*`), never mutate another role's Linear status, never write
Vault / TF state, never SSH to live hosts. The additive guardrail is mandatory and a red
worker PR is opened as a **draft**. See the runbook + the Linear hard-rules list.
