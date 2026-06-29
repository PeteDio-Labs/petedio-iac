#!/usr/bin/env bash
# agent-run-events.sh — bracket a command with run_started / run_exited lifecycle events,
# so run_exited fires even if the wrapped command crashes or is killed (PET-212). This is the
# crash-safe alternative to emitting lifecycle events at the model's discretion: the wrapper
# owns the bracketing (run_started before, run_exited via EXIT trap), mirroring the worker
# harness (scripts/worker/worker-run.sh `trap cleanup EXIT`). The wrapped agent still emits the
# specifics it alone knows — issue_picked, pr_opened — from inside the run.
#
# Intended for the Claude loops that otherwise run `cc` from a bare prompt (authoring loop, and
# the Bucket-B engine tier, PET-184): wrap the cc invocation so a crash still records run_exited.
#
# SECRETS: none. Delegates all MinIO writes to agent-event.sh (preconfigured `mc` alias only).
#
# Usage:
#   scripts/agent-run-events.sh --agent engine [--issue PET-n] [--detail "..."] -- <cmd> [args...]
#   scripts/agent-run-events.sh --agent loop -- cc --model claude-opus-4-8 -p "$PROMPT"
#
# Honors the same AGENT_EVENTS_MC_ALIAS / AGENT_EVENTS_PATH env as agent-event.sh, plus:
#   AGENT_EVENTS_DRY_RUN=true   pass --dry-run through to agent-event.sh (no mc needed)
set -euo pipefail

die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVENT="$SCRIPT_DIR/agent-event.sh"
[ -x "$EVENT" ] || die "agent-event.sh not found/executable next to this script."

AGENT="" ISSUE="" DETAIL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --agent) AGENT="$2"; shift 2 ;;
    --issue) ISSUE="$2"; shift 2 ;;
    --detail) DETAIL="$2"; shift 2 ;;
    --) shift; break ;;
    -h | --help) sed -n '2,20p' "$0"; exit 0 ;;
    *) die "unknown arg: $1 (did you forget '--' before the command?)" ;;
  esac
done

[ -n "$AGENT" ] || die "--agent is required (worker|reviewer|loop|engine)."
[ $# -gt 0 ] || die "no command after '--' to run."

DRY=()
[ "${AGENT_EVENTS_DRY_RUN:-}" = "true" ] && DRY=(--dry-run)

# Best-effort emit: telemetry must never take down the wrapped run.
emit() { "$EVENT" --agent "$AGENT" "${DRY[@]}" "$@" >/dev/null 2>&1 || true; }

# run_exited fires on ANY exit path (clean, error, signal) — this is the whole point.
STATUS=0
on_exit() {
  STATUS=$?
  local d="exit=$STATUS"
  [ -n "$DETAIL" ] && d="$DETAIL $d"
  if [ -n "$ISSUE" ]; then emit --event run_exited --issue "$ISSUE" --detail "$d"
  else emit --event run_exited --detail "$d"; fi
}
trap on_exit EXIT

if [ -n "$ISSUE" ]; then emit --event run_started --issue "$ISSUE" --detail "$DETAIL"
else emit --event run_started --detail "$DETAIL"; fi

# Hand off to the wrapped command; its exit code becomes ours (and feeds the trap).
"$@"
