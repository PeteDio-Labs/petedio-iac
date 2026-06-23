#!/usr/bin/env bash
# reviewer-log-verdict.sh — append one verdict row to the JSONL eval log in MinIO.
#
# The REVIEWER half of the two-agent system (PET-135): the labeled eval dataset. One row
# per reviewed PR, appended to a flat JSONL object (`agent-evals/verdicts.jsonl`) so we
# can later measure worker success rate and reviewer precision/recall vs Pedro. Schema
# (decided 2026-06-10):
#   {"ts","issue","pr","worker_model","harness","worker_tests","claude_verdict",
#    "claude_findings":[],"pedro_verdict","round_trips","tokens","wall_s"}
# The reviewer fills its fields now; Pedro's `pedro_verdict` (merge|kickback) is appended
# on merge/kickback — left "" here.
#
# Object stores can't append in place, so this does download -> append a line -> upload
# via `mc`. There is exactly ONE serial reviewer, so no lock is needed (same single-
# operator assumption as the TF state backend); if that ever changes, this read-modify-
# write races and needs a real lock.
#
# SECRETS: none here. `mc` reads its credentials from a preconfigured alias
# (`mc alias set`), which Pedro seeds from Vault `kv/services/agent-loop` (mc_access_key /
# mc_secret_key) — path reference only, never embedded. See docs/runbooks/reviewer-loop.md.
#
# Usage:
#   scripts/reviewer/reviewer-log-verdict.sh \
#     --issue PET-42 --pr 17 \
#     --worker-tests pass|fail --claude-verdict approve|changes \
#     [--worker-model MODEL] [--harness NAME] \
#     [--findings-json '["finding one","finding two"]'] \
#     [--round-trips N] [--tokens N] [--wall-s N] \
#     [--pedro-verdict merge|kickback] \
#     [--dry-run]            # print the row, do NOT upload (no mc needed)
#
# Env (optional):
#   REVIEWER_MC_ALIAS       mc alias for the homelab MinIO (default: homelab)
#   REVIEWER_VERDICTS_PATH  bucket/key for the log (default: agent-evals/verdicts.jsonl)
set -euo pipefail

die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

ISSUE="" PR="" WORKER_MODEL="" HARNESS="" WORKER_TESTS="" CLAUDE_VERDICT=""
FINDINGS_JSON="[]" PEDRO_VERDICT="" ROUND_TRIPS="0" TOKENS="0" WALL_S="0" DRY_RUN=false

while [ $# -gt 0 ]; do
  case "$1" in
    --issue) ISSUE="$2"; shift 2 ;;
    --pr) PR="$2"; shift 2 ;;
    --worker-model) WORKER_MODEL="$2"; shift 2 ;;
    --harness) HARNESS="$2"; shift 2 ;;
    --worker-tests) WORKER_TESTS="$2"; shift 2 ;;
    --claude-verdict) CLAUDE_VERDICT="$2"; shift 2 ;;
    --findings-json) FINDINGS_JSON="$2"; shift 2 ;;
    --pedro-verdict) PEDRO_VERDICT="$2"; shift 2 ;;
    --round-trips) ROUND_TRIPS="$2"; shift 2 ;;
    --tokens) TOKENS="$2"; shift 2 ;;
    --wall-s) WALL_S="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h | --help) sed -n '2,40p' "$0"; exit 0 ;;
    *) die "unknown arg: $1 (see --help)" ;;
  esac
done

command -v python3 >/dev/null || die "python3 not in PATH (jq isn't on the loop host)."

# --- validate the constrained fields up front (a bad row pollutes the eval set) ---
[ -n "$ISSUE" ] || die "--issue is required (e.g. PET-42)."
[ -n "$PR" ] || die "--pr is required."
case "$WORKER_TESTS" in pass | fail) ;; *) die "--worker-tests must be pass|fail (got '$WORKER_TESTS')." ;; esac
case "$CLAUDE_VERDICT" in approve | changes) ;; *) die "--claude-verdict must be approve|changes (got '$CLAUDE_VERDICT')." ;; esac
case "$PEDRO_VERDICT" in "" | merge | kickback) ;; *) die "--pedro-verdict must be merge|kickback if set (got '$PEDRO_VERDICT')." ;; esac
for n in "$ROUND_TRIPS" "$TOKENS" "$WALL_S"; do
  [[ "$n" =~ ^[0-9]+$ ]] || die "--round-trips/--tokens/--wall-s must be non-negative integers (got '$n')."
done

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Build the row with python so JSON escaping + the findings-array parse are correct.
ROW="$(
  ISSUE="$ISSUE" PR="$PR" WORKER_MODEL="$WORKER_MODEL" HARNESS="$HARNESS" \
  WORKER_TESTS="$WORKER_TESTS" CLAUDE_VERDICT="$CLAUDE_VERDICT" FINDINGS_JSON="$FINDINGS_JSON" \
  PEDRO_VERDICT="$PEDRO_VERDICT" ROUND_TRIPS="$ROUND_TRIPS" TOKENS="$TOKENS" WALL_S="$WALL_S" TS="$TS" \
  python3 <<'PY'
import json, os, sys

try:
    findings = json.loads(os.environ["FINDINGS_JSON"])
except json.JSONDecodeError as e:
    sys.exit(f"--findings-json is not valid JSON: {e}")
if not isinstance(findings, list):
    sys.exit("--findings-json must be a JSON array")

row = {
    "ts": os.environ["TS"],
    "issue": os.environ["ISSUE"],
    "pr": os.environ["PR"],
    "worker_model": os.environ["WORKER_MODEL"],
    "harness": os.environ["HARNESS"],
    "worker_tests": os.environ["WORKER_TESTS"],
    "claude_verdict": os.environ["CLAUDE_VERDICT"],
    "claude_findings": findings,
    "pedro_verdict": os.environ["PEDRO_VERDICT"],
    "round_trips": int(os.environ["ROUND_TRIPS"]),
    "tokens": int(os.environ["TOKENS"]),
    "wall_s": int(os.environ["WALL_S"]),
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

ALIAS="${REVIEWER_MC_ALIAS:-homelab}"
VPATH="${REVIEWER_VERDICTS_PATH:-agent-evals/verdicts.jsonl}"
TARGET="${ALIAS}/${VPATH}"

mc alias list "$ALIAS" >/dev/null 2>&1 ||
  die "mc alias '$ALIAS' not configured. Seed it from Vault kv/services/agent-loop (see docs/runbooks/reviewer-loop.md)."

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

# Download the existing log (empty if the object doesn't exist yet — first verdict).
if mc stat "$TARGET" >/dev/null 2>&1; then
  mc cat "$TARGET" >"$TMP" 2>/dev/null || die "could not read existing $TARGET."
  # Ensure a trailing newline so the appended row starts on its own line.
  [ -s "$TMP" ] && [ "$(tail -c1 "$TMP")" != "" ] && printf '\n' >>"$TMP"
fi
printf '%s\n' "$ROW" >>"$TMP"

mc pipe "$TARGET" <"$TMP" >/dev/null 2>&1 || die "upload to $TARGET failed (bucket exists? alias creds valid?)."
printf '\033[1;32mappended verdict for %s (PR %s) to %s\033[0m\n' "$ISSUE" "$PR" "$TARGET" >&2
