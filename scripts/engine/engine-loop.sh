#!/usr/bin/env bash
# engine-loop.sh — one scheduled tick of the engine (PET-184, Phase 0d/0e).
#
# The engine is the LOWEST-priority consumer of the shared Claude Max quota (Pedro > reviewer >
# engine), so it runs BOXED and YIELDING. A systemd timer fires this script; each tick does at
# most ONE unit of work and exits (freeing the slot), exactly like the reviewer's one-PR-per-
# iteration rule. Priority is enforced by four guards, then a single-slot mutex:
#
#   1. PAUSE sentinel   — ~/engine/PAUSED exists → park (Pedro's kill-switch / "I'm active").
#   2. off-hours window — ENGINE_OFFHOURS="22-7" and now outside it → park (unattended S1 runs
#                         off-hours only; leave unset for anytime).
#   3. reviewer-preempt — ~/engine/REVIEWER_ACTIVE exists → yield (the reviewer is short + event-
#                         driven and outranks the engine).
#   4. cc-slot flock    — `flock -n` on the single cc-slot: if any other automated Claude Code
#                         session (a prior engine tick, the reviewer) holds it → exit. ONE
#                         automated cc session at a time on 242.
#
# WORK SELECTION (resume before new — finish what's started, minimize wasted quota):
#   a. a paused_cap task whose reset has passed  → resume it;
#   b. else a gate_red task                      → another pass to get it green;
#   c. else the oldest queued task               → start it.
# Picking a NEW Bucket-B issue + reading its spec needs Linear judgment (Claude via MCP, per
# docs/runbooks/engine-loop.md), so the interactive side ENQUEUES work and this unattended timer
# DRAINS it — that split is the S0→S1 supervision ramp. Nothing to do → exit 0 (idle, not error).
#
# Subcommands:
#   engine-loop.sh                              run one tick (the systemd timer's ExecStart).
#   engine-loop.sh enqueue PET-<n> --repo <owner/repo> [--slug <slug>] --spec-file <f>|--spec -
#                                               queue a curated Bucket-B task for the timer.
#   engine-loop.sh status                       print queue + in-flight state (read-only).
#
# Env: ENGINE_HOME (~/engine) · ENGINE_STATE_DIR (~/engine/state) · ENGINE_SLOT_LOCK
#      (/run/lock/cc-slot, falls back to ~/engine/cc-slot.lock) · ENGINE_OFFHOURS (unset) ·
#      plus every ENGINE_* var engine-run.sh honors (ENGINE_MODEL, ENGINE_MAX_TURNS, …).
set -euo pipefail

log()  { printf '\033[1;34m[engine-loop] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[engine-loop] ERROR: %s\033[0m\n' "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN="$SCRIPT_DIR/engine-run.sh"
[ -x "$RUN" ] || die "engine-run.sh not found/executable: $RUN"

ENGINE_HOME="${ENGINE_HOME:-$HOME/engine}"
STATE_DIR="${ENGINE_STATE_DIR:-$ENGINE_HOME/state}"
QUEUE_DIR="$ENGINE_HOME/queue"
PAUSE_FILE="$ENGINE_HOME/PAUSED"
REVIEWER_ACTIVE="$ENGINE_HOME/REVIEWER_ACTIVE"
SLOT_LOCK="${ENGINE_SLOT_LOCK:-/run/lock/cc-slot}"
export ENGINE_STATE_DIR="$STATE_DIR"
mkdir -p "$STATE_DIR" "$QUEUE_DIR"

meta_get() { grep -E "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2- || true; }

# --- subcommand: enqueue ----------------------------------------------------------------
if [ "${1:-}" = enqueue ]; then
  shift; QN="" QREPO="" QSLUG="" QSPEC=""
  while [ $# -gt 0 ]; do case "$1" in
    --repo) QREPO="$2"; shift 2 ;;
    --slug) QSLUG="$2"; shift 2 ;;
    --spec-file|--spec) QSPEC="$2"; shift 2 ;;
    PET-*) QN="$1"; shift ;;
    *) die "enqueue: unexpected arg '$1'" ;;
  esac; done
  [[ "$QN" =~ ^PET-[0-9]+$ ]] || die "enqueue: first arg must be PET-<n>."
  [ -n "$QREPO" ] || die "enqueue: --repo <owner/repo> required."
  [ -n "$QSPEC" ] || die "enqueue: --spec-file <f> or --spec - required."
  d="$QUEUE_DIR/$QN"; mkdir -p "$d"
  if [ "$QSPEC" = "-" ]; then cat >"$d/spec.md"; else [ -f "$QSPEC" ] || die "spec file not found: $QSPEC"; cp "$QSPEC" "$d/spec.md"; fi
  { printf 'repo=%s\n' "$QREPO"; [ -n "$QSLUG" ] && printf 'slug=%s\n' "$QSLUG"; printf 'queued_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; } >"$d/meta"
  log "enqueued $QN ($QREPO) → $d"
  exit 0
fi

# --- subcommand: status -----------------------------------------------------------------
if [ "${1:-}" = status ]; then
  printf 'queued:\n'; ls -1 "$QUEUE_DIR" 2>/dev/null | sed 's/^/  /' || true
  printf 'in-flight state:\n'
  for s in "$STATE_DIR"/PET-*.json; do [ -e "$s" ] || continue
    python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print("  %s %s reset=%s"%(d["issue"],d["phase"],d.get("reset_at")))' "$s" 2>/dev/null || true
  done
  exit 0
fi
[ $# -eq 0 ] || die "unknown subcommand '$1' (use: <none> | enqueue | status)."

# --- guard 1: pause sentinel ------------------------------------------------------------
[ -e "$PAUSE_FILE" ] && { log "PAUSED sentinel present ($PAUSE_FILE) — parking."; exit 0; }

# --- guard 2: off-hours window ----------------------------------------------------------
if [ -n "${ENGINE_OFFHOURS:-}" ]; then
  start="${ENGINE_OFFHOURS%-*}"; end="${ENGINE_OFFHOURS#*-}"; now_h="$(date +%-H)"
  in_window=false
  if [ "$start" -le "$end" ]; then [ "$now_h" -ge "$start" ] && [ "$now_h" -lt "$end" ] && in_window=true
  else [ "$now_h" -ge "$start" ] || [ "$now_h" -lt "$end" ] && in_window=true; fi   # wraps midnight
  [ "$in_window" = true ] || { log "outside off-hours window ($ENGINE_OFFHOURS, now=${now_h}h) — parking."; exit 0; }
fi

# --- guard 3: reviewer preempt ----------------------------------------------------------
[ -e "$REVIEWER_ACTIVE" ] && { log "reviewer active ($REVIEWER_ACTIVE) — yielding."; exit 0; }

# --- guard 4: cc-slot flock (single automated Claude Code session on 242) ---------------
if ! exec 9>"$SLOT_LOCK" 2>/dev/null; then
  SLOT_LOCK="$ENGINE_HOME/cc-slot.lock"; exec 9>"$SLOT_LOCK" || die "cannot open a cc-slot lock file."
fi
flock -n 9 || { log "cc-slot busy (another automated cc session holds it) — exiting."; exit 0; }
log "cc-slot acquired ($SLOT_LOCK)."

# --- select ONE unit of work (resume before new) ----------------------------------------
NOW_TS="$(date -u +%s)"
pick=""   # "PET-<n>"
pick_reason=""

# a/b: an in-flight task worth resuming (paused_cap past reset, or gate_red).
for s in "$STATE_DIR"/PET-*.json; do
  [ -e "$s" ] || continue
  phase="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("phase",""))' "$s" 2>/dev/null || true)"
  key="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("issue",""))' "$s" 2>/dev/null || true)"
  [ -n "$key" ] || continue
  case "$phase" in
    paused_cap)
      reset="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("reset_at") or "")' "$s" 2>/dev/null || true)"
      # Best-effort: if we can parse a future reset and it hasn't passed, skip; unparseable → try.
      rts="$(date -u -d "$reset" +%s 2>/dev/null || true)"
      if [ -n "$rts" ] && [ "$rts" -gt "$NOW_TS" ]; then log "$key paused until $reset — not yet."; continue; fi
      pick="$key"; pick_reason="resume-after-cap"; break ;;
    gate_red) pick="$key"; pick_reason="retry-gate-red"; break ;;
  esac
done

# c: else the oldest queued task.
if [ -z "$pick" ]; then
  for d in "$QUEUE_DIR"/PET-*; do
    [ -d "$d" ] || continue
    pick="$(basename "$d")"; pick_reason="new-from-queue"; break
  done
fi

[ -n "$pick" ] || { log "nothing to do (no resumable state, empty queue) — idle."; exit 0; }
log "selected $pick ($pick_reason)."

# --- resolve repo + spec (queue on first start, cached in state dir on resume) ----------
QDIR="$QUEUE_DIR/$pick"
SPEC_CACHE="$STATE_DIR/${pick}.spec.md"; META_CACHE="$STATE_DIR/${pick}.meta"
if [ -d "$QDIR" ]; then
  cp -f "$QDIR/spec.md" "$SPEC_CACHE"; cp -f "$QDIR/meta" "$META_CACHE"   # promote queue → active cache
fi
[ -f "$SPEC_CACHE" ] && [ -f "$META_CACHE" ] || { log "no cached spec/meta for $pick — skipping (re-enqueue it)."; exit 0; }
REPO="$(meta_get "$META_CACHE" repo)"; SLUG="$(meta_get "$META_CACHE" slug)"
[ -n "$REPO" ] || die "$pick meta has no repo=."

SLUG_ARG=(); [ -n "$SLUG" ] && SLUG_ARG=(--slug "$SLUG")
log "→ engine-run.sh $pick --repo $REPO ($pick_reason)"
set +e
"$RUN" "$pick" --repo "$REPO" "${SLUG_ARG[@]}" --spec-file "$SPEC_CACHE"
rc=$?
set -e

case "$rc" in
  0) log "$pick completed (rc=0)."; rm -rf "$QDIR" ;;                          # done → drop the queue entry
  3) log "$pick no-op (rc=3) — done, nothing produced."; rm -rf "$QDIR" ;;
  4) log "$pick paused on usage-cap (rc=4) — will resume a later tick." ;;      # keep queue+state for resume
  *) log "$pick engine-run errored (rc=$rc) — leaving state for inspection." ;;
esac
exit 0
