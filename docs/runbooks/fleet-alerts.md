# Fleet needs-human push alerts (PET-256) — runbook

`scripts/fleet-alert.sh` on agent-loop-242 is the **push half** of the fleet view: it reads
the same MinIO eval logs the page renders and sends an **ntfy** notification to Pedro's
phone when the fleet needs a human — instead of the stall waiting to be discovered on the
next page visit (PR #56 once sat unreviewed ~6h).

## What alerts

- **A. needs-human events** — any new `stalled` / `escalated_needs_human` row in
  `events.jsonl` (events older than 48h never alert, so a fresh install doesn't replay
  history).
- **B. unreviewed PRs** — a worker/engine run opened a PR, no `verdicts.jsonl` row exists
  for its (PET, PR), it's older than `FLEET_ALERT_REVIEW_HOURS` (default 2), **and GitHub
  still shows it open** (merged/closed PRs are recorded and never re-checked).

Each alert key is deduped in `~/.fleet-alert-state` after a successful send — one push per
condition, not one per tick.

## One-time setup

1. Pick a hard-to-guess topic name (it's the only credential — anyone who knows it can post
   to it): e.g. `petedio-fleet-$(openssl rand -hex 6)`.
2. Seed Vault: `vault kv patch kv/services/agent-loop ntfy_topic=<topic>`.
3. On the phone: install the ntfy app, subscribe to the topic (server `https://ntfy.sh`, or
   set `FLEET_NTFY_URL` in the unit for self-hosted).
4. Prove it: as the loop user on 242, `scripts/fleet-alert.sh --dry-run` (prints WOULD-ALERT
   lines, sends nothing), then once without `--dry-run` to receive the real pushes.
5. Flip `agent_loop_fleet_alert_timer_enabled: true` in
   `ansible/inventory/host_vars/agent-loop-242.yml` and run `configure-agent-loop.yml`.

## Tuning / rollback

- Cadence: `agent_loop_fleet_alert_oncalendar` (default every 10 min).
- Threshold: `agent_loop_fleet_alert_review_hours` (default 2).
- Re-arm an alert: delete its line from `~/.fleet-alert-state`.
- Rollback: flip the host_var back (or `systemctl disable --now fleet-alert.timer`).
