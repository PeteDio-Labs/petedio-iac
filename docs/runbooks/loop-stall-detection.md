# Loop stall detection — auto-release stuck In-Progress issues (PET-147)

PET-37 sat **In Progress for 2+ days with no PR and no comment** — invisible until someone
checked by hand. Stall detection makes the queue self-heal: an issue the **loop** moved to
*In Progress* that shows no PR/comment activity for N hours (default **12**) gets an
automatic "stalled — releasing" comment and is moved back to its prior state.

## Two halves (by access)

| Half | Who | What |
|---|---|---|
| **GitHub signal** — `scripts/loop-stall-check.sh PET-<n> …` | a plain script (cron-safe) | Read-only: per key, is there a `pet-<n>-*` branch / a PR, and how stale (`--hours`, default 12)? Flags `github_artifact=false` (no branch, no PR) and `pr_stale`. |
| **Linear decision + release** | the **loop** (Claude + MCP) | List the loop's In-Progress issues + their `startedAt`/last-activity; decide stalls; post the comment + reset state. A headless cron can't reach Linear without a token (Manual steps). |

The In-Progress **timer** and the **state reset** are inherently Linear-side; the script only
provides the deterministic "has the loop produced any GitHub artifact, and is it stale" signal.

## The stall-sweep standing prompt (loop, Claude + MCP)

```
Stall sweep (PET-147):
1. Via Linear MCP, list issues currently In Progress that the LOOP moved there (the loop's
   own claims — NEVER touch a human-claimed In-Progress issue). For each, get startedAt and
   the timestamp of the last comment/update.
2. Run `scripts/loop-stall-check.sh PET-<n> [PET-<m> …] --json` for the GitHub signal.
3. An issue is STALLED when ALL hold:
     - In Progress for > 12h (startedAt), AND
     - no comment/activity on the issue in > 12h, AND
     - `github_artifact=false` (no pet-<n>-* branch and no PR) OR the only PR is `pr_stale`
       AND the issue was never moved to In Review.
   A recent PR (or one already In Review) is NOT a stall — it's progressing.
4. For each stalled issue:
     - Post once: "🕳️ Stalled — no PR/comment in >12h since In Progress at <startedAt>.
       Auto-releasing to <prior state> so the queue self-heals (PET-147). Verify any merge
       claim via scripts/pr-merge-status.sh." (idempotent — the state reset removes it from
       the In-Progress set, so it won't re-fire.)
     - Move it back to its PRIOR state (from Linear's state history — the state before
       In Progress, usually Todo/Backlog). This is the loop reverting its OWN claim, which
       is within the authoring loop's status authority — it is NOT moving someone else's issue.
5. Report what was released in the run summary.
```

## Why the loop may reset THIS status (and not others)

The shared protocol says the worker/reviewer never move Linear status and the authoring loop
moves status only per its run protocol (claim → In Progress; done → In Review). Releasing a
**stale self-claim** is the inverse of the claim the loop itself made — it only ever un-does
the loop's own `→ In Progress`, never a human's or another role's status. If the issue carries
`needs-human`, leave it (that label means no agent touches it).

## Scheduling

- **Now (loop-driven):** run the sweep as a periodic loop iteration (cheap — the script is
  read-only and Linear reads are quick).
- **Headless (after the Manual step):** a 242 systemd timer (mirror the PET-148
  `rebase-loop-prs.timer`) once a Linear token exists.

## Manual steps for Pedro

- A fully-headless stall sweep needs a **Linear API token by Vault path** (e.g.
  `kv/services/linear`, field `api_key`) — same reference-only pattern as the loop's GitHub
  token; none is provisioned yet, so the Linear half runs through the loop's MCP today. Shared
  with PET-145 (post-merge sweep) — one token serves both.

## Related

- PET-145 (post-merge sweep) — sibling reconciliation; same Linear-token boundary.
- PET-146 (`scripts/pr-merge-status.sh`) — verify any merge claim before asserting it.
