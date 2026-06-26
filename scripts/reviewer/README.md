# `scripts/reviewer/` — the reviewer loop (PET-135)

Helper scripts for the **reviewer half** of the two-agent system on `agent-loop-242`. They
gather the facts Claude needs to review a worker PR (candidate list, independent test
result) and record the verdict (JSONL eval log). The **judgment** — diff review, findings,
approve/changes — is Claude's, per the standing prompt.

Full operational guide, the standing prompt, and Pedro's one-time setup:
**[`docs/runbooks/reviewer-loop.md`](../../docs/runbooks/reviewer-loop.md)**.

| Script | What it does |
|---|---|
| `reviewer-candidates.sh` | Read-only: list open, non-draft Co-latro PRs not authored by the reviewer, with the parsed `PET-<n>` key (JSON). |
| `reviewer-checkout-test.sh <owner/repo> <pr>` | Clone in `/tmp`, detached-checkout the PR head, run `bun install` + `bun test` independently, print pass/fail + output tail (JSON). |
| `reviewer-log-verdict.sh …` | Append one schema-valid JSONL row to `agent-evals/verdicts.jsonl` in MinIO (`--dry-run` to preview). |
| `reviewer-stamp-pedro-verdict.sh …` | Stamp Pedro's `merge\|kickback` verdict onto the matching existing row (join on PET key + PR). Operator-run after merge/kickback; `--dry-run` to preview (PET-191). |
| `templates/pr-verdict.md.tmpl` | PR-review body skeleton. |
| `templates/linear-verdict.md.tmpl` | Linear-comment skeleton. |

**Hard rules:** these scripts never merge, never push to worker branches, never mutate
Linear status, never read Vault secrets (mc creds come from a preconfigured alias), and the
reviewer never reviews its own PRs. See the runbook + the Linear hard-rules list.
