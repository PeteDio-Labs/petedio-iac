#!/usr/bin/env bash
# reviewer-round-trips.sh — count the worker↔reviewer round-trips on a PR (PET-199).
#
# The REVIEWER half of the two-agent system. `verdicts.jsonl` has a `round_trips` field
# meant to measure how many times the reviewer kicked a PR back before approving — but
# nothing computed it, so every row logged `round_trips: 0` and the fleet view's RT column
# read flat. This makes it deterministic: a round-trip is one prior `CHANGES_REQUESTED`
# review the reviewer posted on the PR. So:
#   - first pass, approve with no history        → 0
#   - changes-requested once, then re-review     → 1
#   - changes-requested twice (the cap), then …  → 2
# Pass the count straight to `reviewer-log-verdict.sh --round-trips`.
#
# READ-ONLY: only ever runs `gh pr view` / `gh api user`. Never checks out, comments, or
# writes anything. `gh` resolves auth from the env (GH_TOKEN or `gh auth`); never printed.
#
# Usage:
#   scripts/reviewer/reviewer-round-trips.sh <owner/repo> <pr-number>
#   e.g. scripts/reviewer/reviewer-round-trips.sh PeteDio-Labs/co-latro-backend 42
#
# Env (optional):
#   REVIEWER_SELF_LOGIN  the reviewer's GitHub login — only its CHANGES_REQUESTED reviews
#                        count (default: `gh api user`; empty falls back to counting ALL
#                        CHANGES_REQUESTED reviews, since the reviewer is the only agent
#                        that requests changes on worker PRs).
#
# Output (stdout): a single non-negative integer. Exit non-zero only on a harness failure
# (bad args, gh error) — a PR with no reviews prints 0 and exits 0.
set -euo pipefail

die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ $# -eq 2 ] || die "usage: $(basename "$0") <owner/repo> <pr-number>"
REPO="$1"
PR="$2"
[[ "$PR" =~ ^[0-9]+$ ]] || die "pr-number must be numeric (got '$PR')."

for t in gh python3; do command -v "$t" >/dev/null || die "$t not in PATH."; done

# Resolve the reviewer login once (so a human's CHANGES_REQUESTED never inflates the count).
# Tolerate an offline/unauth gh: empty SELF means "count all changes-requested".
SELF="${REVIEWER_SELF_LOGIN:-}"
if [ -z "$SELF" ]; then
  SELF="$(gh api user --jq .login 2>/dev/null || true)"
fi

REVIEWS_JSON="$(gh pr view "$PR" --repo "$REPO" --json reviews 2>/dev/null)" ||
  die "gh pr view failed for $REPO#$PR (PR exists? token valid?)."

REVIEWER_SELF="$SELF" python3 - "$REVIEWS_JSON" <<'PY'
import json, os, sys

data = json.loads(sys.argv[1] or "{}")
reviews = data.get("reviews", []) or []
self_login = os.environ["REVIEWER_SELF"].strip()

count = 0
for r in reviews:
    if r.get("state") != "CHANGES_REQUESTED":
        continue
    author = (r.get("author") or {}).get("login", "") or ""
    # When we know the reviewer login, only count its kickbacks; otherwise count all
    # (the reviewer is the only agent that requests changes on worker PRs).
    if self_login and author != self_login:
        continue
    count += 1

print(count)
PY
