#!/usr/bin/env bash
# loop-stall-check.sh — the GitHub-side signal for loop stall detection (PET-147).
#
# PET-37 sat In Progress for 2+ days with no PR and no comment — invisible until checked by
# hand. Stall detection auto-releases such issues. The authoritative "stalled" decision is
# Linear-side (how long has it been In Progress; any recent comment) and the release (a
# "stalled — releasing" comment + state reset to the prior state) is done by the loop via the
# Linear MCP — a headless cron can't reach Linear without a token (see
# docs/runbooks/loop-stall-detection.md). This script answers the part shell does well and
# deterministically: for each PET-<n>, has the loop produced ANY GitHub artifact (a
# `pet-<n>-*` branch / a PR), and how stale is it?
#
# READ-ONLY: only `git ls-remote` + `gh pr list`. Never comments, pushes, or changes state.
#
# Usage:
#   scripts/loop-stall-check.sh PET-37 PET-146 ...   [--json] [--hours N] [--repo owner/repo]
#   (defaults: --hours 12 — the proposed stall threshold; --repo PeteDio-Labs/petedio-iac)
#
# Output per key (table default, or --json array):
#   {pet, has_branch, pr_number, pr_state, pr_updated_at, hours_since_pr_update,
#    github_artifact, pr_stale}
#   github_artifact=false  → no branch AND no PR: the strongest "no PR activity" stall signal.
#   pr_stale=true          → a PR exists but hasn't been touched in >--hours.
# The loop combines this with Linear's In-Progress duration to decide a release. `gh` uses
# GH_TOKEN from the env; never printed.
set -euo pipefail

die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

JSON=false HOURS=12 REPO="PeteDio-Labs/petedio-iac" KEYS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=true; shift ;;
    --hours) HOURS="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    -h | --help) sed -n '2,30p' "$0"; exit 0 ;;
    -*) die "unknown arg: $1 (see --help)" ;;
    *) KEYS+=("$1"); shift ;;
  esac
done
[ "${#KEYS[@]}" -gt 0 ] || die "give one or more PET-<n> keys. See --help."
[[ "$HOURS" =~ ^[0-9]+$ ]] || die "--hours must be a non-negative integer (got '$HOURS')."

for t in gh git python3 date; do command -v "$t" >/dev/null || die "$t not in PATH."; done

NOW_EPOCH="$(date -u +%s)"
ORG_REPO_URL="https://github.com/${REPO}.git"

# Build a TSV the python pass turns into table/JSON: pet<TAB>has_branch<TAB>pr_json.
# Captured into a var and passed as argv (NOT piped) — the python script itself arrives via
# the heredoc on stdin, so data must come through a different channel.
DATA=""
for key in "${KEYS[@]}"; do
  num="${key#[Pp][Ee][Tt]-}"
  [[ "$num" =~ ^[0-9]+$ ]] || die "bad PET key '$key' (want PET-<n>)."
  if git ls-remote --heads "$ORG_REPO_URL" "pet-${num}-*" 2>/dev/null | grep -q .; then
    has_branch=true
  else
    has_branch=false
  fi
  # First PR whose title carries the key (loop PRs are titled "[PET-n] …"). `tr -d '\n'`
  # flattens gh's JSON to one line (JSON is whitespace-insensitive) so it's a safe TSV field.
  pr="$(gh pr list --repo "$REPO" --search "PET-${num} in:title" --state all --limit 1 \
    --json number,state,updatedAt 2>/dev/null | tr -d '\n' || echo '[]')"
  [ -n "$pr" ] || pr='[]'
  DATA+="PET-${num}"$'\t'"${has_branch}"$'\t'"${pr}"$'\n'
done

NOW_EPOCH="$NOW_EPOCH" HOURS="$HOURS" JSON="$JSON" python3 - "$DATA" <<'PY'
import json, os, sys
from datetime import datetime, timezone

now = int(os.environ["NOW_EPOCH"])
hours_thr = int(os.environ["HOURS"])
as_json = os.environ["JSON"] == "true"
rows = []

for line in sys.argv[1].splitlines():
    if not line.strip():
        continue
    pet, has_branch, pr_json = line.split("\t", 2)
    prs = json.loads(pr_json) if pr_json.strip() else []
    pr = prs[0] if prs else None
    hours_since = None
    if pr and pr.get("updatedAt"):
        upd = datetime.strptime(pr["updatedAt"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        hours_since = round((now - int(upd.timestamp())) / 3600, 1)
    rows.append({
        "pet": pet,
        "has_branch": has_branch == "true",
        "pr_number": pr.get("number") if pr else None,
        "pr_state": pr.get("state") if pr else None,
        "pr_updated_at": pr.get("updatedAt") if pr else None,
        "hours_since_pr_update": hours_since,
        "github_artifact": (has_branch == "true") or bool(pr),
        "pr_stale": (hours_since is not None and hours_since > hours_thr),
    })

if as_json:
    json.dump(rows, sys.stdout, indent=2); sys.stdout.write("\n")
else:
    print(f"GitHub stall signal (threshold {hours_thr}h):")
    for r in rows:
        if not r["github_artifact"]:
            sig = "NO GITHUB ARTIFACT (no branch, no PR) — strong stall candidate"
        elif r["pr_number"] is None:
            sig = "branch but NO PR — possible mid-work stall"
        elif r["pr_stale"]:
            sig = f"PR #{r['pr_number']} {r['pr_state']}, stale {r['hours_since_pr_update']}h"
        else:
            sig = f"PR #{r['pr_number']} {r['pr_state']}, active {r['hours_since_pr_update']}h ago"
        print(f"  {r['pet']:<9} {sig}")
    print("\nCombine with Linear's In-Progress duration to decide a release. See "
          "docs/runbooks/loop-stall-detection.md.")
PY
