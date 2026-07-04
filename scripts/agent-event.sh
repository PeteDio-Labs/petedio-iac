#!/usr/bin/env bash
# agent-event.sh — append one lifecycle event to the unified JSONL stream (PET-154).
#
# Unified telemetry for every agent role (worker-243, reviewer-242, authoring loop + engine
# tier on 242): the data layer for Mission Control v3 (PET-158 board / PET-155 viewer). Every
# agent emits
# one JSONL row to `agent-evals/events.jsonl` (same MinIO bucket as the PET-135 verdict log)
# at each lifecycle point. Built alongside PET-135 — same bucket + same append mechanism.
#
# Schema (one object per line):
#   {"ts","agent":"worker|reviewer|loop|engine","event","issue":"PET-n|null","pr":<int>|null,"detail"}
#
# `loop` = the Claude authoring loop (Platform/IaC); `engine` = the Bucket-B engine tier (PET-184)
# authoring new effect kinds in the Co-latro repos. Same lifecycle events, distinct lane.
#
# Events: run_started · issue_picked · pr_opened · verdict_posted · changes_requested ·
#         stalled · escalated_needs_human · run_exited · cap_paused · cap_resumed
#         (cap_paused/cap_resumed, PET-257: a quota/off-hours/preempt park — informational,
#          NOT a needs-human alert; the engine emits one per contiguous parked stretch)
#
# Object stores can't append in place, so this does download -> append a line -> upload via
# `mc` (exactly like reviewer-log-verdict.sh). One serial writer per host, so no lock needed.
#
# SECRETS: none here. `mc` reads its credentials from a preconfigured alias (`mc alias set`),
# seeded from Vault by the operator — path reference only, never embedded. See
# docs/runbooks/agent-event-stream.md.
#
# Usage:
#   scripts/agent-event.sh --agent loop --event issue_picked --issue PET-42 [--pr 64] [--detail "…"]
#   scripts/agent-event.sh --agent reviewer --event verdict_posted --issue PET-42 --pr 64 --detail approve
#   scripts/agent-event.sh --agent loop --event run_started            # issue/pr optional
#   ... --dry-run    # print the row, do NOT upload (no mc needed)
#
# Env (optional):
#   AGENT_EVENTS_MC_ALIAS   mc alias for the homelab MinIO (default: homelab)
#   AGENT_EVENTS_PATH       bucket/key for the stream (default: agent-evals/events.jsonl)
#
# TESTING (PET-221): smoke/e2e/probe runs MUST NOT pollute the prod stream that fleet.pdlab.dev
# reads. Either pass --dry-run (prints the row, no upload), or point AGENT_EVENTS_PATH at a
# throwaway key, e.g. `AGENT_EVENTS_PATH=agent-evals/events.test.jsonl`. The fleet view reads
# only `events.jsonl`, so a `.test.jsonl` sibling is invisible to it. (Fake PET keys like
# PET-9999 / PET-105105 previously leaked in this way and had to be scrubbed by hand.)
set -euo pipefail

die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

AGENT="" EVENT="" ISSUE="" PR="" DETAIL="" DRY_RUN=false
while [ $# -gt 0 ]; do
  case "$1" in
    --agent) AGENT="$2"; shift 2 ;;
    --event) EVENT="$2"; shift 2 ;;
    --issue) ISSUE="$2"; shift 2 ;;
    --pr) PR="$2"; shift 2 ;;
    --detail) DETAIL="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h | --help) sed -n '2,33p' "$0"; exit 0 ;;
    *) die "unknown arg: $1 (see --help)" ;;
  esac
done

command -v python3 >/dev/null || die "python3 not in PATH (jq isn't on the loop host)."

# --- validate the constrained fields (a bad row pollutes the telemetry set) ---
case "$AGENT" in worker | reviewer | loop | engine) ;; *) die "--agent must be worker|reviewer|loop|engine (got '$AGENT')." ;; esac
case "$EVENT" in
  run_started | issue_picked | pr_opened | verdict_posted | changes_requested | stalled | escalated_needs_human | run_exited | cap_paused | cap_resumed) ;;
  *) die "--event '$EVENT' is not a known lifecycle event (see --help)." ;;
esac
[ -z "$ISSUE" ] || [[ "$ISSUE" =~ ^PET-[0-9]+$ ]] || die "--issue must look like PET-<n> (got '$ISSUE')."
[ -z "$PR" ] || [[ "$PR" =~ ^[0-9]+$ ]] || die "--pr must be a positive integer (got '$PR')."

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Build the row with python so JSON escaping (detail) + the int/null pr are correct.
ROW="$(
  AGENT="$AGENT" EVENT="$EVENT" ISSUE="$ISSUE" PR="$PR" DETAIL="$DETAIL" TS="$TS" \
  python3 <<'PY'
import json, os, sys
row = {
    "ts": os.environ["TS"],
    "agent": os.environ["AGENT"],
    "event": os.environ["EVENT"],
    "issue": os.environ["ISSUE"] or None,
    "pr": int(os.environ["PR"]) if os.environ["PR"] else None,
    "detail": os.environ["DETAIL"],
}
# Compact single line — JSONL is one object per line.
sys.stdout.write(json.dumps(row, separators=(",", ":"), ensure_ascii=False))
PY
)"

if [ "$DRY_RUN" = true ]; then
  printf '%s\n' "$ROW"
  exit 0
fi

command -v mc >/dev/null || die "mc not in PATH (install via roles/agent-loop, agent_loop_install_mc)."

ALIAS="${AGENT_EVENTS_MC_ALIAS:-homelab}"
VPATH="${AGENT_EVENTS_PATH:-agent-evals/events.jsonl}"
TARGET="${ALIAS}/${VPATH}"

mc alias list "$ALIAS" >/dev/null 2>&1 ||
  die "mc alias '$ALIAS' not configured. Seed it from Vault kv/services/agent-loop (see docs/runbooks/agent-event-stream.md)."

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

# Download the existing stream (empty if the object doesn't exist yet — first event).
if mc stat "$TARGET" >/dev/null 2>&1; then
  mc cat "$TARGET" >"$TMP" 2>/dev/null || die "could not read existing $TARGET."
  # Ensure a trailing newline so the appended row starts on its own line.
  [ -s "$TMP" ] && [ "$(tail -c1 "$TMP")" != "" ] && printf '\n' >>"$TMP"
fi
printf '%s\n' "$ROW" >>"$TMP"

mc pipe "$TARGET" <"$TMP" >/dev/null 2>&1 || die "upload to $TARGET failed (bucket exists? alias creds valid?)."
printf '\033[1;32mevent %s/%s (%s) -> %s\033[0m\n' "$AGENT" "$EVENT" "${ISSUE:-–}" "$TARGET" >&2
