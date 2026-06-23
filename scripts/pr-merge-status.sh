#!/usr/bin/env bash
# pr-merge-status.sh — emit a VERIFIED PR merge/state line for loop comments (PET-146).
#
# Cycle 2 lesson: a loop comment claimed "PR #50 merged to main" when it hadn't synced
# (hard rule 7). Agents must NEVER assert merge state from memory — always read it from the
# API. This is the loop wrapper for that rule: it calls `gh pr view --json mergedAt,state,...`
# and prints one ready-to-paste line so any comment about PR state embeds the real `mergedAt`.
#
# READ-ONLY: only ever runs `gh pr view`. Never merges, comments, or mutates anything.
#
# Usage:
#   scripts/pr-merge-status.sh <pr-number|branch|url> [--json] [--repo owner/repo]
#
# Exit code is the machine signal (so callers can GUARD on it, not just read text):
#   0 = MERGED   1 = open / closed-unmerged (i.e. NOT merged)   2 = error (PR not found / gh)
# So `scripts/pr-merge-status.sh 65 && echo "safe to call it merged"` only fires when verified.
#
# Output (default): one line, e.g.
#   PR #62 — MERGED at 2026-06-23T19:26:49Z [verified via gh API 2026-06-23T21:14Z]
#   PR #65 — OPEN, NOT merged (mergedAt: null); mergeable=MERGEABLE, state=BLOCKED [verified …]
# `--json` prints the raw verified fields instead.
set -euo pipefail

die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 2; }

PR="" JSON=false REPO_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=true; shift ;;
    --repo) REPO_ARGS=(--repo "$2"); shift 2 ;;
    -h | --help) sed -n '2,24p' "$0"; exit 0 ;;
    -*) die "unknown arg: $1 (see --help)" ;;
    *) PR="$1"; shift ;;
  esac
done
[ -n "$PR" ] || die "usage: $(basename "$0") <pr-number|branch|url> [--json] [--repo owner/repo]"

for t in gh python3 date; do command -v "$t" >/dev/null || die "$t not in PATH."; done

# The single source of truth: the GitHub API via gh. No cached/asserted state.
RAW="$(gh pr view "$PR" "${REPO_ARGS[@]}" \
  --json number,state,mergedAt,mergeStateStatus,mergeable,url,title 2>/dev/null)" ||
  die "gh pr view '$PR' failed (PR exists? authenticated? right repo?)."

CHECKED_AT="$(date -u +%Y-%m-%dT%H:%MZ)"

if [ "$JSON" = true ]; then
  CHECKED_AT="$CHECKED_AT" python3 - "$RAW" <<'PY'
import json, os, sys
d = json.loads(sys.argv[1]); d["checked_at"] = os.environ["CHECKED_AT"]
json.dump(d, sys.stdout, indent=2); sys.stdout.write("\n")
PY
  # In --json mode the exit code still reflects merged-ness for guards.
  printf '%s' "$RAW" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("mergedAt") else 1)'
  exit $?
fi

# Human line + merged-ness exit code, both derived from the SAME API read.
CHECKED_AT="$CHECKED_AT" python3 - "$RAW" <<'PY'
import json, os, sys

d = json.loads(sys.argv[1])
n, state = d.get("number"), d.get("state", "?")
merged_at = d.get("mergedAt")
checked = os.environ["CHECKED_AT"]

if merged_at:
    print(f"PR #{n} — MERGED at {merged_at} [verified via gh API {checked}]")
    sys.exit(0)

print(
    f"PR #{n} — {state}, NOT merged (mergedAt: null); "
    f"mergeable={d.get('mergeable','?')}, mergeStateStatus={d.get('mergeStateStatus','?')} "
    f"[verified via gh API {checked}]"
)
sys.exit(1)
PY
