#!/usr/bin/env bash
# reviewer-candidates.sh — enumerate worker PRs that may need a reviewer pass.
#
# The REVIEWER half of the two-agent system (PET-135). This is the "poll" step:
# READ-ONLY by construction — it only ever runs `gh pr list` / `gh api user`, never
# checks out, comments, labels, or merges. It prints a JSON array of open, non-draft
# Co-latro PRs that are NOT authored by the reviewer's own GitHub account (hard rule:
# the reviewer never reviews its own PRs), each annotated with the PET-<n> key parsed
# from the branch then the title.
#
# It deliberately does NOT decide reviewability on its own. The In-Review status, the
# "not yet agent-reviewed" filter, and the max-2-round-trips cap live in Linear and are
# applied by Claude (Linear MCP) per docs/runbooks/reviewer-loop.md — a shell script
# can't see Linear state. This script just narrows "every open PR" down to "open worker
# PRs not mine", so Claude reasons over a short list.
#
# Usage:
#   scripts/reviewer/reviewer-candidates.sh
#
# Env (all optional):
#   REVIEWER_REPOS        space-separated owner/repo list to poll
#                         (default: PeteDio-Labs/co-latro-backend
#                                   PeteDio-Labs/co-latro-frontend)
#   REVIEWER_SELF_LOGIN   GitHub login to exclude as author (default: `gh api user`).
#                         The reviewer must never review its OWN PRs.
#
# Output (stdout): JSON array, one object per candidate:
#   {"repo","number","title","author","headRefName","baseRefName","url","pet","isDraft"}
# Exit 0 with `[]` when nothing is open. `gh` must be authenticated (GH_TOKEN or
# `gh auth`); the token stays in the environment — never printed.
set -euo pipefail

die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

command -v gh >/dev/null || die "gh not in PATH."
command -v python3 >/dev/null || die "python3 not in PATH (jq isn't on the loop host)."

REPOS="${REVIEWER_REPOS:-PeteDio-Labs/co-latro-backend PeteDio-Labs/co-latro-frontend}"

# Self = the account whose PRs we must skip. Resolve once; tolerate an offline/unauth gh
# by falling back to empty (then nothing is excluded — Claude still skips its own by URL).
SELF="${REVIEWER_SELF_LOGIN:-}"
if [ -z "$SELF" ]; then
  SELF="$(gh api user --jq .login 2>/dev/null || true)"
fi

# Collect each repo's open PRs as JSON and merge/annotate in one python pass. We pass the
# raw `gh` JSON per repo on stdin as a JSON object stream keyed by repo, so the PET-key
# parsing + self-filter is testable in one place.
emit_repo_json() {
  local repo="$1"
  # --state open already excludes closed/merged; isDraft lets us drop WIP PRs.
  gh pr list --repo "$repo" --state open --limit 50 \
    --json number,title,author,headRefName,baseRefName,url,isDraft \
    2>/dev/null || echo '[]'
}

{
  for repo in $REPOS; do
    printf '%s\t' "$repo"
    emit_repo_json "$repo"
    printf '\n'
  done
} | python3 -c '
import json, re, sys

self_login = sys.argv[1].strip()
PET = re.compile(r"PET-(\d+)", re.IGNORECASE)

out = []
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line.strip():
        continue
    repo, _, payload = line.partition("\t")
    try:
        prs = json.loads(payload) if payload.strip() else []
    except json.JSONDecodeError:
        continue
    for pr in prs:
        if pr.get("isDraft"):
            continue
        author = (pr.get("author") or {}).get("login", "") or ""
        if self_login and author == self_login:
            continue  # never review our own PRs (hard rule)
        m = PET.search(pr.get("headRefName", "") or "") or PET.search(pr.get("title", "") or "")
        out.append({
            "repo": repo.strip(),
            "number": pr.get("number"),
            "title": pr.get("title", ""),
            "author": author,
            "headRefName": pr.get("headRefName", ""),
            "baseRefName": pr.get("baseRefName", ""),
            "url": pr.get("url", ""),
            "pet": ("PET-" + m.group(1)) if m else None,
            "isDraft": bool(pr.get("isDraft")),
        })

json.dump(out, sys.stdout, indent=2)
sys.stdout.write("\n")
' "$SELF"
