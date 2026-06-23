# Post-merge status sweep — Linear ↔ GitHub drift (PET-145)

Linear's GitHub PR sync has **missed merge events** (PR #50 showed open days after merging;
PET-123 stuck *In Review* after its PR merged). This sweep catches that drift: it lists
recently **merged** PRs and reconciles each against its Linear issue, so a merged-but-not-Done
issue surfaces within one cron cycle.

## Two halves (by trust + access)

| Half | Who runs it | What it does |
|---|---|---|
| **GitHub side** — `scripts/post-merge-sweep.sh` | a plain script (cron-safe) | Read-only `gh`: list PRs merged in the last `--days` (default 14), parse the `PET-<n>` key, print a table or `--json`. Never comments/labels/merges. |
| **Linear side** — reconciliation | the **loop** (Claude + Linear MCP) | For each merged PR, check the PET issue's status; if it isn't Done/closed, post a **one-time** drift comment. **Status changes stay human-owned.** |

Why split: the loop reaches Linear through the **MCP**, not a raw API key, so a headless cron
can't do the Linear half without a token that isn't provisioned yet (see *Manual steps*). The
GitHub half is deterministic and testable on its own; the judgment + commenting stay with Claude.

## The sweep standing prompt (loop, Claude + MCP)

Run as part of a loop iteration (or its own scheduled wake):

```
Reconcile Linear ↔ GitHub merge drift (PET-145):
1. Run `scripts/post-merge-sweep.sh --json --days 14` for the merged-PR list (ground truth).
2. For each row with a `pet` key, get the Linear issue (MCP). If its PR is merged
   (verify via `gh pr view <n> --json mergedAt`) but the issue is NOT Done/closed
   (still In Review / In Progress / Todo), it has drifted.
3. For each drifted issue, post ONE reconciliation comment — but ONLY if no prior
   "post-merge sweep" comment already exists on it (idempotent; never spam). Quote the
   PR #, its mergedAt, and the current Linear status. DO NOT change the Linear status —
   that stays human/integration-owned (hard rules; the issue says so explicitly).
4. Rows with `pet=null` (no key in branch/title): note them in your run summary so the
   convention gap is visible; don't guess an issue.
```

A drift comment should read, e.g.:
> 🔁 **Post-merge sweep (PET-145):** PR #62 merged `2026-06-23T19:26Z`, but this issue is
> still **In Review**. Linear's GitHub sync likely missed the merge — please reconcile the
> status. (Sweep posts this once; status changes stay human-owned.)

## Scheduling

- **Now (loop-driven):** fold the standing prompt into the authoring-loop cadence, or wake
  it on its own. The script is read-only, so running it often is cheap.
- **Headless cron (after the Manual step below):** a systemd timer on agent-loop-242 (mirror
  the PET-148 `rebase-loop-prs.timer` pattern) could run a fully-headless version once a
  Linear token exists. The GitHub half already runs headless today.

## Manual steps for Pedro

- **A fully-headless Linear half needs a Linear API token** the cron can read **by Vault
  path** (e.g. `kv/services/linear`, field `api_key`) — same reference-only pattern as the
  loop's GitHub token. None is provisioned yet, so today the Linear reconciliation runs
  through the loop's MCP. If you want it headless, provision that token + path and say so,
  and I'll add the Linear-GraphQL half to the script (status-read + idempotent comment)
  behind a `LINEAR_API_KEY`-or-Vault fallback.
- The sweep only ever **comments**; it never changes Linear status (kept human/integration-
  owned per the issue). If you later want it to auto-move *In Review → Done* on a verified
  merge, that's a separate decision.

## Related

- Hard rule 7 (verify merge claims via `gh pr view --json mergedAt`) — the sweep's whole
  point is that the loop never asserts a merge it hasn't verified.
- PET-146 (merge-claim verification wrapper) and PET-147 (stall detection) are siblings in
  the loop-hardening set.
