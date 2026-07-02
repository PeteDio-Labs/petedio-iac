#!/usr/bin/env bash
# worker-loop.sh — one scheduled tick of the worker auto-launch (PET-184 S1).
#
# S0 → S1: today a human hand-runs worker-run.sh per issue. This is the auto-launch: a systemd
# timer fires each tick and the worker picks its own work. The worker is the FREE tier (local
# Ollama, no shared Claude quota), so unlike the engine it needs NO cc-slot / off-hours / cap
# handling — just a single-instance lock + a PAUSED kill-switch.
#
# Per tick: poll worker-candidates.sh (Todo + worker-ok Co-latro issues, WITH their bodies) →
# pick the oldest not launched within the cooldown → run worker-run.sh with the issue body as
# the spec. ONE issue per tick. The GitHub↔Linear link moves the issue OUT of Todo the moment
# the PR opens, so the loop advances on its own and needs only READ Linear access — it never
# writes Linear. The cooldown just rides out the integration's status-update lag so a slow
# link can't make two ticks pick the same issue.
#
# Usage:  worker-loop.sh            one tick (the systemd timer's ExecStart)
#         worker-loop.sh status     candidates + recent launches (read-only)
# Env: WORKER_HOME (~/worker) · WORKER_LAUNCH_COOLDOWN_MIN (default 30) · plus every WORKER_* /
#      WORKER_LINEAR_* var worker-candidates.sh + worker-run.sh already honor.
set -uo pipefail
log() { printf '\033[1;34m[worker-loop] %s\033[0m\n' "$*" >&2; }
die() { printf '\033[1;31m[worker-loop] ERROR: %s\033[0m\n' "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CANDIDATES="$SCRIPT_DIR/worker-candidates.sh"
RUN="$SCRIPT_DIR/worker-run.sh"
[ -x "$CANDIDATES" ] || die "worker-candidates.sh not found/executable."
[ -x "$RUN" ] || die "worker-run.sh not found/executable."

WORKER_HOME="${WORKER_HOME:-$HOME/worker}"
PAUSE_FILE="$WORKER_HOME/PAUSED"
LAUNCH_DIR="$WORKER_HOME/launched"
LOCK="$WORKER_HOME/worker-loop.lock"
COOLDOWN_MIN="${WORKER_LAUNCH_COOLDOWN_MIN:-30}"
mkdir -p "$LAUNCH_DIR"

# --- status subcommand (read-only) ------------------------------------------------------
if [ "${1:-}" = status ]; then
  echo "candidates:"
  "$CANDIDATES" 2>/dev/null | python3 -c 'import json,sys
try: [print("  %-8s %s" % (i.get("key",""), (i.get("title","") or "")[:60])) for i in json.load(sys.stdin)]
except Exception: print("  (none / no Linear token)")' 2>/dev/null || echo "  (none / no Linear token)"
  echo "recent launches:"; ls -1t "$LAUNCH_DIR" 2>/dev/null | head -8 | sed 's/^/  /' || true
  exit 0
fi
[ $# -eq 0 ] || die "unknown subcommand '$1' (use: <none> | status)."

# --- guard 1: pause sentinel ------------------------------------------------------------
[ -e "$PAUSE_FILE" ] && { log "PAUSED sentinel present ($PAUSE_FILE) — parking."; exit 0; }

# --- guard 2: single-instance lock (never overlap two worker ticks) ---------------------
exec 9>"$LOCK" || die "cannot open lock file $LOCK."
flock -n 9 || { log "another worker tick holds the lock — exiting."; exit 0; }

# --- poll candidates --------------------------------------------------------------------
CANDS="$("$CANDIDATES" 2>/dev/null || echo '[]')"
COUNT="$(printf '%s' "$CANDS" | python3 -c 'import json,sys
try: print(len(json.load(sys.stdin)))
except Exception: print(0)' 2>/dev/null || echo 0)"
[ "${COUNT:-0}" -gt 0 ] || { log "no worker-ok Todo candidates (or no Linear token reachable) — idle."; exit 0; }

# --- pick the oldest candidate not launched within the cooldown; spec → a temp file -----
SPEC_F="$(mktemp "${TMPDIR:-/tmp}/worker-loop-spec-XXXXXX")"
NOW="$(date +%s)"; COOLDOWN_S=$((COOLDOWN_MIN * 60))
PICK="$(CANDS="$CANDS" LAUNCH_DIR="$LAUNCH_DIR" NOW="$NOW" COOLDOWN_S="$COOLDOWN_S" SPEC_F="$SPEC_F" python3 <<'PY'
import json, os
cands = json.loads(os.environ["CANDS"])
ld, now, cd, specf = os.environ["LAUNCH_DIR"], int(os.environ["NOW"]), int(os.environ["COOLDOWN_S"]), os.environ["SPEC_F"]
for c in cands:
    key = c.get("key", "")
    if not key:
        continue
    m = os.path.join(ld, key)
    if os.path.exists(m) and now - os.path.getmtime(m) < cd:
        continue  # launched recently — let the Linear status catch up before re-picking
    open(specf, "w").write(c.get("description", "") or "")
    print("\t".join([key, c.get("repo", ""), c.get("branch_slug", "")]))  # no tabs/newlines in these
    break
PY
)"
if [ -z "$PICK" ]; then rm -f "$SPEC_F"; log "all candidates launched within the ${COOLDOWN_MIN}m cooldown — nothing new."; exit 0; fi

KEY="$(printf '%s' "$PICK" | cut -f1)"
REPO="$(printf '%s' "$PICK" | cut -f2)"
SLUG="$(printf '%s' "$PICK" | cut -f3)"
[ -n "$REPO" ] || { rm -f "$SPEC_F"; log "$KEY has no resolvable repo — skipping."; exit 0; }
[ -s "$SPEC_F" ] || { rm -f "$SPEC_F"; log "$KEY has an empty body — skipping (worker specs need a 'Do:' section that names the target file)."; exit 0; }

# --- launch (mark first so a crash mid-run still cools it down) --------------------------
touch "$LAUNCH_DIR/$KEY"
log "launching $KEY  repo=$REPO  slug=$SLUG"
"$RUN" "$KEY" --repo "$REPO" --slug "$SLUG" --spec-file "$SPEC_F"
rc=$?
rm -f "$SPEC_F"
log "$KEY worker-run exited rc=$rc"
exit 0
