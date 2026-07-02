# Reviewer loop — agent-loop-242 (PET-135)

The **reviewer half** of the two-agent system. Claude Code on `agent-loop-242` reviews
worker PRs: pulls each branch, runs `bun test` **independently** (never trusts the
worker's reported result), posts a structured verdict on the PR **and** the Linear issue,
sets labels, and appends a row to the JSONL eval log in MinIO. It **never merges, never
mutates Linear status, never reviews its own PRs.**

Authoritative protocol: the Linear docs **[Reviewer Operations — agent-loop-242]** and the
shared **[Agent Loop Operations]** (hard rules apply verbatim). This runbook is the on-host
operational companion — the scripts, the standing prompt, and Pedro's one-time setup.

## Scripts (`scripts/reviewer/`)

| Script | Role | Mutates? |
|---|---|---|
| `reviewer-candidates.sh` | Read-only `gh`: list open, non-draft Co-latro PRs **not** authored by the reviewer's own account, annotated with the parsed `PET-<n>` key. | No (read-only) |
| `reviewer-checkout-test.sh <owner/repo> <pr>` | Clone fresh in `/tmp`, check out the PR head **detached**, run `bun install` + `bun test`, print pass/fail + output tail as JSON. Temp dir always removed. | No (isolated /tmp; never pushes) |
| `reviewer-round-trips.sh <owner/repo> <pr>` | Read-only `gh`: count the prior `CHANGES_REQUESTED` reviews the reviewer posted on the PR — the value for `--round-trips` (0 on a clean first approve, 1 after one kickback, …). | No (read-only) |
| `reviewer-log-verdict.sh …` | Append one schema-valid JSONL row to `agent-evals/verdicts.jsonl` in MinIO via `mc` (download → append → upload). `--dry-run` prints the row without uploading. | Appends to MinIO only |
| `reviewer-stamp-poll.sh [--dry-run]` | Auto-stamp `pedro_verdict` onto closed worker PRs (merged → merge, closed-unmerged → kickback) by delegating to `reviewer-stamp-pedro-verdict.sh`. Runs on a systemd timer (PET-199); only touches rows with an empty `pedro_verdict`. | Stamps MinIO (via the PET-191 writer) |
| `templates/pr-verdict.md.tmpl` | PR-review body skeleton (tests result, findings, one-line merge rec). | — |
| `templates/linear-verdict.md.tmpl` | Linear-comment skeleton (same, self-contained for Pedro's fast-merge filter). | — |

The scripts do what shell does well (enumerate PRs, run tests, write the log). The
**judgment** — reading the diff against the repo `CLAUDE.md`, writing findings, choosing
approve/changes — is Claude's, driven by the standing prompt below.

> **Test env (PET-178).** The host runs a **local throwaway Postgres** (`postgres` /
> `colatro` on `localhost:5432`, role var `agent_loop_install_test_postgres`) matching
> co-latro-backend's default `DATABASE_URL`, so `reviewer-checkout-test.sh`'s `bun test` is
> **green at baseline** (verified: full suite 297 pass / 0 fail). Treat any failure as a
> *real* regression — there is no longer an "ignore the N env DB/server fails" caveat (the
> worker's authoring self-check gets the same clean signal).

## The reviewer standing prompt

There is no `run-loop.sh` (same as the authoring loop). Run `cc` (Claude Code) as `agent`
in a tmux session and give it this prompt. `cc` pins `--model claude-opus-4-8`
(`agent_loop_cc_command`), so the verdict is always decided by that Opus build — never the
ambient picker default, never a Mythos-class model (Fable 5 / Mythos 5).

```
You are the REVIEWER half of the two-agent loop on agent-loop-242. Read the Linear docs
"Reviewer Operations — agent-loop-242" and "Agent Loop Operations" in full first — the
hard rules bind you (no merge, no apply/import/state, no SSH to live hosts, no Vault
secrets in output, never change Linear status, never review your OWN PRs).

Each iteration:
1. Run `scripts/reviewer/reviewer-candidates.sh` to list open worker PRs.
2. For each candidate, check Linear (MCP): is its issue In Review, NOT already
   `agent-reviewed`, and authored by the worker (not you)? Skip the rest. Pick the
   oldest unreviewed one. If a PR already has `changes-requested` and this would be the
   3rd round-trip, post a `needs-human` comment instead and stop on it.
3. Run `scripts/reviewer/reviewer-checkout-test.sh <owner/repo> <pr>` — this is the
   GROUND TRUTH test result. Never substitute the worker's claim.
4. Read the diff (`gh pr diff`) against the repo's CLAUDE.md + conventions; read the PR's
   verification-evidence block (PET-149).
5. Fill `templates/pr-verdict.md.tmpl` and post it as the **`petedio-reviewer[bot]`**
   identity — distinct from the PR author, so no self-review block (PET-176):
   `GH_TOKEN="$(scripts/reviewer/reviewer-mint-token.sh)" gh pr review <pr> --approve|--request-changes --body-file <file>`.
6. Fill `templates/linear-verdict.md.tmpl` and post it as a Linear comment. Set the label
   `agent-reviewed` (and `changes-requested` if requesting changes). DO NOT change status.
7. Append the eval row. Get the round-trip count first
   (`scripts/reviewer/reviewer-round-trips.sh <owner/repo> <pr>`), and always pass
   `--reviewer-model` (the model YOU are — the pinned Opus build) so the row records who
   decided the verdict, not just the worker it reviewed:
   `scripts/reviewer/reviewer-log-verdict.sh --issue PET-<n> --pr <pr> \
      --worker-tests pass|fail --claude-verdict approve|changes \
      --findings-json '[...]' --worker-model <model> --harness <harness> \
      --reviewer-model claude-opus-4-8 --round-trips <n>`
   (`--dry-run` first to eyeball it. `--reviewer-model` defaults to `claude-opus-4-8`, so a
   forgotten flag still records the pinned model — but pass it explicitly.)
8. One PR per iteration. If anything is ambiguous or risky, comment and stop.

You do **not** stamp `pedro_verdict` — that's the merge/kickback half, auto-filled by the
`reviewer-stamp-poll.sh` timer after Pedro acts (below).
```

## Pedro's one-time setup (Manual steps)

These are operator-only — the loop is author-only and never does them.

1. **MinIO eval bucket** (the loop can't create it — no mutation creds):
   ```sh
   mc mb homelab/agent-evals          # on a box with the admin mc alias
   mc version enable homelab/agent-evals   # versioning = the recovery net (no lock)
   ```
2. **`mc` alias on 242**, creds from Vault (path reference only — never inline):
   ```sh
   # as agent@242, with the Vault Agent token already on disk (~/.vault-token):
   AK=$(vault kv get -field=mc_access_key kv/services/agent-loop)
   SK=$(vault kv get -field=mc_secret_key kv/services/agent-loop)
   mc alias set homelab http://192.168.50.221:9000 "$AK" "$SK"   # MinIO .221 serves http, not https
   ```
   The scoped svcacct only needs read/write on `agent-evals` — mint it bucket-scoped
   (same pattern as `scripts/reseed-minio-frontend-vault.sh`), not the tfstate credential
   (`kv/iac/minio` is tfstate-only — see GOTCHAS).
3. **`mc` binary on 242**: installed by `roles/agent-loop` (`agent_loop_install_mc`,
   default true) — re-run `ansible-playbook playbooks/configure-agent-loop.yml`.
4. **Start the loop**: attach the tmux session in `~/work/petedio/iac`, run `cc`, paste the
   standing prompt. Run the first iterations supervised.

## Verdict log schema (`agent-evals/verdicts.jsonl`)

One JSON object per line (decided 2026-06-10; `reviewer_model` added 2026-06-26, PET-199):

```json
{"ts":"","issue":"PET-n","pr":"","worker_model":"","harness":"","reviewer_model":"","worker_tests":"pass|fail","claude_verdict":"approve|changes","claude_findings":[],"pedro_verdict":"merge|kickback","round_trips":0,"tokens":0,"wall_s":0}
```

`worker_model`/`harness` describe the PR **under review** (the worker that authored it);
`reviewer_model` is the model that **decided** the verdict (the pinned Opus build — see
`roles/agent-loop` `agent_loop_claude_model`). The reviewer fills its fields; `pedro_verdict`
(merge|kickback) is the merge/kickback half. This is the labeled eval set: worker success
rate, reviewer precision/recall vs Pedro, and gold failures (bugs that slip both gates).

**`pedro_verdict` is auto-stamped (PET-199).** A systemd timer on 242 runs
`scripts/reviewer/reviewer-stamp-poll.sh`, which reads each recently-closed worker PR's final
state and stamps the matching row: **merged → `merge`, closed-unmerged → `kickback`**. It only
touches rows with an empty `pedro_verdict`, so it never re-writes a manual stamp. Pedro can
still stamp/override by hand —
`scripts/reviewer/reviewer-stamp-pedro-verdict.sh --issue PET-<n> --verdict merge|kickback
[--pr <pr>] [--allow-overwrite]` (PET-191; `--dry-run` first, `--pr` to disambiguate when one
PET key has several rows).

> A 242-side **poller**, not a merge-triggered GitHub Action — which dodges the three reasons
> an Action was rejected: worker PRs live in the Co-latro app repos (the poller scans every
> repo from one host, no per-repo Action), a merge event can only ever record `merge` and
> never `kickback` (reading close-state captures both), and the eval log is a single-operator
> serial-writer object with no lock (the timer stays the lone writer on the loop host). See
> the script's RACE NOTE — it's a second automated writer; cadence is modest + MinIO is
> versioned.

## Hard limits (restated)

- Review + comment + label + append-to-log only. **No** merges, commits to worker
  branches, `apply`/`import`/state, SSH to live hosts, or Vault reads in output.
- **Never review your own PRs** — those wait for Pedro.
- Max **2 round-trips** with the worker, then a `needs-human` comment.
- Verify any merge claim via `gh pr view --json mergedAt` before asserting it (PET-146) —
  use the wrapper `scripts/pr-merge-status.sh <pr>`: it prints a ready-to-paste verified line
  and exits 0 only when actually merged, so a comment can never assert a merge from memory.

[Reviewer Operations — agent-loop-242]: https://linear.app/petedillo/document/reviewer-operations-agent-loop-242-e7e7014c9f23
[Agent Loop Operations]: https://linear.app/petedillo/document/agent-loop-operations-living-doc-agent-reads-every-run-bf14d40272b9
