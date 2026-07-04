# Bucket-A auto-merge (PET-185) — runbook

`scripts/automerge-poll.sh` on agent-loop-242 squash-merges **trivial additive worker PRs**
without Pedro; engine/logic PRs always stay human-merge. Decision of 2026-06-25 (PET-185),
implemented as a 242-side poller (same three reasons as the stamp poller: one host covers
every repo, it can read the MinIO eval logs GitHub-native rules can't see, and the eval log
keeps its serial-writer invariant).

## The predicate (ALL must hold — see the script header for the authoritative list)

open + non-draft + worker-authored + no `needs-human`/`changes-requested` label + **latest**
verdict row for its (PET, PR) is `approve` + `worker-runs` guard=ok whose `head_sha` prefixes
the PR's *current* head + every check SUCCESS incl. `build` + every changed file inside the
per-file catalog allowlist (`src/engine/{jokers,consumables,tags,vouchers}/`, PET-216).

After a merge: verified via `mergedAt` (never asserted), an `auto_merged` event is appended to
`events.jsonl`, and `reviewer-stamp-poll` stamps `pedro_verdict=merge` on its next tick —
an auto-merge counts as an accepted verdict in the reviewer-precision eval.

## Merge identity — petedio-merge[bot] (one-time operator setup)

The reviewer must never merge (hard rule) and the worker/engine Apps structurally cannot
(push + open-PR scope only), so merging uses a **fourth** GitHub App:

1. GitHub → Settings → Developer settings → New GitHub App `petedio-merge`:
   permissions **Contents: Read & write** + **Pull requests: Read & write**, no webhooks;
   install it on `co-latro-backend` (+ any future Bucket-A repo).
2. Seed Vault (same path the other identities use):
   ```sh
   vault kv patch kv/services/agent-loop \
     merge_app_id=<app id> merge_installation_id=<installation id> merge_app_pem=@merge.pem
   ```
3. Verify the four App ids are all DIFFERENT (worker/reviewer/engine/merge) — identical ids
   collapse identities and resurrect GitHub's self-review block.

`agent-mint-token.sh merge` then mints its 1-hour installation token on demand. Fallback
order in the script: `AUTOMERGE_GH_TOKEN` env → the merge App → the host login's
`gh auth token` (refused if it resolves to the reviewer).

## Go-live / rollback

- Prove it first: as the loop user on 242, `scripts/automerge-poll.sh --dry-run` — it runs
  the full predicate and prints `WOULD-MERGE` lines only.
- Flip `agent_loop_automerge_timer_enabled: true` in
  `ansible/inventory/host_vars/agent-loop-242.yml` and run `configure-agent-loop.yml`
  (same go-live pattern as the worker/engine timers, PET-184). Default stays false.
- Rollback = flip the var back (or `systemctl disable --now automerge-poll.timer`).
- Cadence: `agent_loop_automerge_oncalendar` (default every 10 min, ≤2 merges per tick).

## Watching it

Auto-merges appear on fleet.pdlab.dev as `auto_merged` events and, one stamp-poll tick
later, as `pedro: merge` rows. `journalctl -u automerge-poll` on 242 shows each tick's
per-PR gate decisions (skips say which gate failed).
