#!/usr/bin/env bash
# reviewer-stamp-usage.sh — stamp real tokens/wall_s onto the verdict row a reviewer run
# just logged (PET-258).
#
# The gap: the whole fleet + Pedro share ONE Max plan, but reviewer rows carry tokens:0 —
# the verdict row is appended by the boxed claude run ITSELF (step 6 of the reviewer
# prompt), which cannot know its own final usage. The launcher (reviewer-loop.sh) DOES
# know, right after the run exits: the `claude -p --output-format json` result object
# carries `usage`, and the launcher holds the wall clock. This script writes those two
# numbers onto the row after the fact.
#
# Token convention matches the engine (engine-run.sh): usage.input_tokens + output_tokens
# + cache_creation_input_tokens + cache_read_input_tokens.
#
# SAFETY: only ever touches the NEWEST row matching (--issue, --pr) and only when its
# `tokens` is 0/absent — a row that already has real usage is never overwritten. Same
# read-modify-write + serial-writer caveats as the sibling stamp script (one loop host,
# versioned bucket as the net). READ from MinIO, one WRITE back via `mc pipe`.
#
# Usage:
#   scripts/reviewer/reviewer-stamp-usage.sh --issue PET-42 --pr 17 --tokens 18420 --wall-s 94 [--dry-run]
#
# Env (optional): REVIEWER_MC_ALIAS (homelab) · REVIEWER_VERDICTS_PATH (agent-evals/verdicts.jsonl)
set -euo pipefail

die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

ISSUE="" PR="" TOKENS="" WALL_S="" DRY_RUN=false
while [ $# -gt 0 ]; do
  case "$1" in
    --issue) ISSUE="$2"; shift 2 ;;
    --pr) PR="$2"; shift 2 ;;
    --tokens) TOKENS="$2"; shift 2 ;;
    --wall-s) WALL_S="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h | --help) sed -n '2,24p' "$0"; exit 0 ;;
    *) die "unknown arg: $1 (see --help)" ;;
  esac
done

command -v python3 >/dev/null || die "python3 not in PATH."
[ -n "$ISSUE" ] || die "--issue is required."
[[ "$PR" =~ ^[0-9]+$ ]] || die "--pr must be an integer (got '$PR')."
[[ "$TOKENS" =~ ^[0-9]+$ ]] || die "--tokens must be a non-negative integer (got '$TOKENS')."
[[ "$WALL_S" =~ ^[0-9]+$ ]] || die "--wall-s must be a non-negative integer (got '$WALL_S')."
[ "$TOKENS" -gt 0 ] || { echo "tokens=0 — nothing worth stamping." >&2; exit 0; }

ALIAS="${REVIEWER_MC_ALIAS:-homelab}"
VPATH="${REVIEWER_VERDICTS_PATH:-agent-evals/verdicts.jsonl}"
TARGET="${ALIAS}/${VPATH}"

command -v mc >/dev/null || die "mc not in PATH."
mc alias list "$ALIAS" >/dev/null 2>&1 || die "mc alias '$ALIAS' not configured."

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
mc stat "$TARGET" >/dev/null 2>&1 || die "$TARGET does not exist — nothing to stamp."
mc cat "$TARGET" >"$TMP" 2>/dev/null || die "could not read $TARGET."

NEW="$(
  ISSUE="$ISSUE" PR="$PR" TOKENS="$TOKENS" WALL_S="$WALL_S" python3 - "$TMP" <<'PY'
import json, os, sys

path = sys.argv[1]
issue, pr = os.environ["ISSUE"], os.environ["PR"]
tokens, wall = int(os.environ["TOKENS"]), int(os.environ["WALL_S"])

raw = open(path, encoding="utf-8").read().splitlines()
out = list(raw)
target_i, target_ts = None, ""
for i, line in enumerate(raw):
    if not line.strip():
        continue
    try:
        row = json.loads(line)
    except json.JSONDecodeError as e:
        sys.exit(f"line {i+1} of the log is not valid JSON: {e}")
    if row.get("issue") != issue or str(row.get("pr")) != str(pr):
        continue
    if int(row.get("tokens") or 0) > 0:
        continue                      # real usage already recorded — never overwrite
    ts = str(row.get("ts") or "")
    if ts >= target_ts:               # newest matching zero-token row wins
        target_i, target_ts = i, ts

if target_i is None:
    sys.exit(f"no zero-token row for {issue} PR {pr} — already stamped or never logged.")

row = json.loads(raw[target_i])
row["tokens"] = tokens
if wall > 0 and int(row.get("wall_s") or 0) == 0:
    row["wall_s"] = wall
out[target_i] = json.dumps(row, separators=(",", ":"))
sys.stdout.write("\n".join(out) + "\n")
PY
)" || die "no stampable row (see message above)."

if [ "$DRY_RUN" = true ]; then
  printf '%s' "$NEW"
  exit 0
fi

printf '%s' "$NEW" | mc pipe "$TARGET" >/dev/null 2>&1 ||
  die "upload to $TARGET failed (bucket exists? alias creds valid?)."
printf '\033[1;32mstamped tokens=%s wall_s=%s for %s (PR %s) in %s\033[0m\n' \
  "$TOKENS" "$WALL_S" "$ISSUE" "$PR" "$TARGET" >&2
