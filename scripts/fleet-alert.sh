#!/usr/bin/env bash
# fleet-alert.sh — push a notification when the fleet needs a human (PET-256).
#
# The fleet view is pull-only: stalls were discovered hours late by opening the page
# (PR #56 sat unreviewed ~6h). This is the push half — a oneshot poller on 242 that reads
# the SAME telemetry the page renders and notifies Pedro's phone via ntfy when:
#   A. a NEW `stalled` / `escalated_needs_human` event appears in events.jsonl
#   B. a fleet PR has sat with NO reviewer verdict for > FLEET_ALERT_REVIEW_HOURS
#      (worker-runs/engine-runs row with a pr, no verdicts.jsonl row for that (issue, pr),
#      and GitHub still shows the PR open — merged/closed PRs never alert)
#
# DEDUPE: each alert key (event ts+agent+issue, or repo#pr) is recorded in a state file
# after a successful send, so a condition fires ONCE — not every tick until fixed.
#
# DELIVERY — ntfy (https://ntfy.sh or self-hosted): a plain HTTPS POST, push to the phone
# app subscribed to the topic. The topic name is the only secret-ish value (anyone knowing
# it can post to it) — it lives in Vault kv/services/agent-loop field `ntfy_topic`, read at
# runtime; never committed. FLEET_NTFY_URL overrides the server for self-hosted.
#
# READ-ONLY apart from the POST to ntfy and the local state file. Never merges, comments,
# labels, or writes to MinIO/Linear/GitHub.
#
# Usage:
#   scripts/fleet-alert.sh [--dry-run]     # dry-run: print would-send alerts, no POST/state
#
# Env (all optional):
#   FLEET_ALERT_REVIEW_HOURS   unreviewed-PR age threshold (default: 2)
#   FLEET_ALERT_STATE          dedupe state file (default: ~/.fleet-alert-state)
#   FLEET_NTFY_URL             ntfy server base (default: https://ntfy.sh)
#   FLEET_NTFY_TOPIC           topic override (default: Vault kv/services/agent-loop:ntfy_topic)
#   FLEET_ALERT_MC_ALIAS / FLEET_ALERT_EVALS_PREFIX   (defaults: homelab / agent-evals)
#   GH_TOKEN                   for the open-PR check; else minted via reviewer-mint-token.sh
set -euo pipefail

die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
info() { printf '\033[1;34m%s\033[0m\n' "$*" >&2; }

DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

for t in mc curl python3; do command -v "$t" >/dev/null || die "$t not in PATH."; done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOURS="${FLEET_ALERT_REVIEW_HOURS:-2}"
STATE="${FLEET_ALERT_STATE:-$HOME/.fleet-alert-state}"
NTFY_URL="${FLEET_NTFY_URL:-https://ntfy.sh}"
ALIAS="${FLEET_ALERT_MC_ALIAS:-homelab}"
PREFIX="${FLEET_ALERT_EVALS_PREFIX:-agent-evals}"

# --- topic (the only sensitive value) — env, else Vault via the host's Agent token -------
TOPIC="${FLEET_NTFY_TOPIC:-}"
if [ -z "$TOPIC" ] && command -v vault >/dev/null; then
  TOPIC="$(vault kv get -field=ntfy_topic kv/services/agent-loop 2>/dev/null || true)"
fi
if [ -z "$TOPIC" ] && ! $DRY_RUN; then
  die "no ntfy topic: set FLEET_NTFY_TOPIC or seed kv/services/agent-loop ntfy_topic (see docs/runbooks/fleet-alerts.md)."
fi

touch "$STATE"

# --- read telemetry (same sources the fleet page renders) --------------------------------
EVENTS="$(mc cat "$ALIAS/$PREFIX/events.jsonl" 2>/dev/null || true)"
VERDICTS="$(mc cat "$ALIAS/$PREFIX/verdicts.jsonl" 2>/dev/null || true)"
RUNS="$( { mc cat "$ALIAS/$PREFIX/worker-runs.jsonl" 2>/dev/null;
           mc cat "$ALIAS/$PREFIX/engine-runs.jsonl" 2>/dev/null; } || true)"

# --- compute would-alerts (dedupe against state inside python; emits "key<TAB>message") --
ALERTS="$(
  EVENTS="$EVENTS" VERDICTS="$VERDICTS" RUNS="$RUNS" STATE_FILE="$STATE" HOURS="$HOURS" \
  python3 <<'PY'
import json, os, time
from datetime import datetime, timezone

def rows(env):
    for line in os.environ.get(env, "").splitlines():
        line = line.strip()
        if not line: continue
        try: yield json.loads(line)
        except json.JSONDecodeError: continue

def ts_val(iso):
    try: return datetime.fromisoformat(str(iso).replace("Z", "+00:00")).timestamp()
    except Exception: return 0

seen = set(l.strip() for l in open(os.environ["STATE_FILE"]) if l.strip())
now = time.time()
hours = float(os.environ["HOURS"])
out = []

# A — needs-human events (each distinct event alerts once)
for e in rows("EVENTS"):
    if str(e.get("event")) not in ("stalled", "escalated_needs_human"): continue
    key = f'ev:{e.get("ts")}:{e.get("agent")}:{e.get("issue")}'
    if key in seen: continue
    age_h = (now - ts_val(e.get("ts"))) / 3600
    if age_h > 48: continue                      # ancient history — no replay spam on first run
    msg = f'{e.get("agent")} {e.get("event")}: {e.get("issue") or "?"}' \
          + (f' #{e["pr"]}' if e.get("pr") else "") \
          + (f' — {e.get("detail")}' if e.get("detail") else "")
    out.append((key, msg))

# B — PR opened by a run, no verdict yet, older than the threshold
verdicted = {(str(v.get("issue") or ""), str(v.get("pr") or "")) for v in rows("VERDICTS")}
best = {}
for r in rows("RUNS"):
    if r.get("pr") in (None, ""): continue
    key = (str(r.get("issue") or ""), str(r.get("pr")))
    if ts_val(r.get("ts")) > ts_val(best.get(key, {}).get("ts")):
        best[key] = r
for (issue, pr), r in best.items():
    if (issue, pr) in verdicted: continue
    age_h = (now - ts_val(r.get("ts"))) / 3600
    if age_h < hours: continue
    key = f'rev:{r.get("repo")}#{pr}'
    if key in seen: continue
    out.append((key, f'PR {r.get("repo")}#{pr} ({issue}) unreviewed for {age_h:.1f}h — check the reviewer loop.', (str(r.get("repo") or ""), pr)))

for item in out:
    if len(item) == 3:
        print(f"{item[0]}\t{item[1]}\t{item[2][0]}\t{item[2][1]}")
    else:
        print(f"{item[0]}\t{item[1]}\t\t")
PY
)"
[ -n "$ALERTS" ] || { info "nothing to alert."; exit 0; }

# --- GH open-check for unreviewed-PR alerts (merged/closed never alert), then send -------
if [ -z "${GH_TOKEN:-}" ] && [ -x "$SCRIPT_DIR/reviewer/reviewer-mint-token.sh" ]; then
  GH_TOKEN="$("$SCRIPT_DIR/reviewer/reviewer-mint-token.sh" 2>/dev/null || true)"; export GH_TOKEN
fi

sent=0
while IFS=$'\t' read -r key msg repo pr; do
  if [ -n "$repo" ] && [ -n "$pr" ] && command -v gh >/dev/null && [ -n "${GH_TOKEN:-}" ]; then
    ST="$(gh pr view "$pr" --repo "$repo" --json state --jq .state 2>/dev/null || echo UNKNOWN)"
    if [ "$ST" != "OPEN" ] && [ "$ST" != "UNKNOWN" ]; then
      echo "$key" >>"$STATE"        # settled on GitHub — record so it never re-checks
      continue
    fi
  fi
  if $DRY_RUN; then
    info "WOULD-ALERT [$key] $msg"
    continue
  fi
  if curl -fsS --max-time 10 -H "Title: PeteDio fleet" -H "Tags: robot" \
       -d "$msg" "$NTFY_URL/$TOPIC" >/dev/null; then
    echo "$key" >>"$STATE"
    sent=$((sent + 1))
  else
    info "ntfy send failed for [$key] — will retry next tick."
  fi
done <<<"$ALERTS"

info "done — sent $sent alert(s)."
