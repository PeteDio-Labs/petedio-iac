#!/usr/bin/env bash
# post-merge-sweep.sh — list recently MERGED PRs + their PET-<n> key, so the loop can
# reconcile Linear ↔ GitHub merge-sync drift (PET-145).
#
# Linear's GitHub PR sync has missed merge events (PR #50 showed open days after merging;
# PET-123 stuck In Review post-merge). This is the GitHub-side, READ-ONLY half of the sweep:
# it only ever calls `gh` and prints a report — it never comments, labels, merges, or
# changes any status. The Linear-side reconciliation (cross-check each issue's status; post
# a one-time "PR merged but issue still <status>" comment; status stays human-owned) is done
# by the loop via the Linear MCP — a headless cron can't reach Linear without an API token
# (see docs/runbooks/post-merge-sweep.md). Keeping the GitHub half a plain script makes it
# deterministic and testable; the judgment + commenting stay with Claude.
#
# Usage:
#   scripts/post-merge-sweep.sh [--json] [--days N]
#
# Env (optional):
#   SWEEP_REPO    owner/repo to sweep (default: PeteDio-Labs/petedio-iac)
#   SWEEP_DAYS    lookback window in days (default: 14; --days overrides)
#
# Output: a table (default) or JSON array (--json) of merged PRs in the window:
#   {"number","mergedAt","pet","title","url"}
# PRs with no parseable PET key are still listed (pet=null) — they may still be drifted.
# `gh` uses GH_TOKEN from the env; never printed. Exit 0 even when the window is empty.
set -euo pipefail

die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

JSON=false
DAYS="${SWEEP_DAYS:-14}"
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=true; shift ;;
    --days) DAYS="$2"; shift 2 ;;
    -h | --help) sed -n '2,28p' "$0"; exit 0 ;;
    *) die "unknown arg: $1 (see --help)" ;;
  esac
done
[[ "$DAYS" =~ ^[0-9]+$ ]] || die "--days must be a non-negative integer (got '$DAYS')."

for t in gh python3 date; do command -v "$t" >/dev/null || die "$t not in PATH."; done

REPO="${SWEEP_REPO:-PeteDio-Labs/petedio-iac}"
SINCE="$(date -u -d "${DAYS} days ago" +%Y-%m-%d 2>/dev/null)" ||
  SINCE="$(date -u -v-"${DAYS}"d +%Y-%m-%d)"  # BSD date fallback (macOS operator runs)

# `gh` server-side filters to PRs merged on/after $SINCE; we still re-check mergedAt in
# python (the search granularity is a day) and parse the PET key from branch then title.
RAW="$(gh pr list --repo "$REPO" --state merged --limit 100 \
  --search "merged:>=${SINCE}" \
  --json number,title,mergedAt,headRefName,url 2>/dev/null)" ||
  die "gh pr list failed for $REPO (authenticated?)."

JSON="$JSON" SINCE="$SINCE" REPO="$REPO" python3 - "$RAW" <<'PY'
import json, os, re, sys

prs = json.loads(sys.argv[1] or "[]")
since = os.environ["SINCE"]            # YYYY-MM-DD (UTC)
as_json = os.environ["JSON"] == "true"
PET = re.compile(r"PET-(\d+)", re.IGNORECASE)

rows = []
for pr in prs:
    merged = pr.get("mergedAt") or ""
    if merged[:10] < since:            # ISO dates sort lexically; drop anything older
        continue
    m = PET.search(pr.get("headRefName", "") or "") or PET.search(pr.get("title", "") or "")
    rows.append({
        "number": pr.get("number"),
        "mergedAt": merged,
        "pet": ("PET-" + m.group(1)) if m else None,
        "title": pr.get("title", ""),
        "url": pr.get("url", ""),
    })

rows.sort(key=lambda r: r["mergedAt"], reverse=True)

if as_json:
    json.dump(rows, sys.stdout, indent=2)
    sys.stdout.write("\n")
else:
    if not rows:
        print(f"No PRs merged in {os.environ['REPO']} since {since}.")
    else:
        print(f"Merged PRs in {os.environ['REPO']} since {since} ({len(rows)}):")
        for r in rows:
            pet = r["pet"] or "(no PET key)"
            print(f"  #{r['number']:<5} {r['mergedAt'][:10]}  {pet:<9}  {r['title']}")
        print("\nReconcile each against Linear (MCP): if the PET issue is not Done/closed,")
        print("post a one-time drift comment. Status changes stay human-owned. See")
        print("docs/runbooks/post-merge-sweep.md.")
PY
