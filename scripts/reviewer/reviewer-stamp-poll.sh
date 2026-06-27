#!/usr/bin/env bash
# reviewer-stamp-poll.sh — auto-stamp pedro_verdict onto closed worker PRs (PET-199).
#
# Closes the last open seam in the two-agent loop. `reviewer-log-verdict.sh` writes a row
# with `pedro_verdict: ""`; PET-191's `reviewer-stamp-pedro-verdict.sh` fills it — but only
# when Pedro runs it by hand, so the fleet view's `pedro` column kept going blank. This
# poller runs on a systemd timer on agent-loop-242 and stamps the verdict automatically by
# reading each PR's final state:
#   merged           → pedro_verdict = merge
#   closed, unmerged → pedro_verdict = kickback
# It only ever touches rows the reviewer already logged with an EMPTY pedro_verdict, so a
# PR with no verdict row (e.g. a human PR) is never stamped, and an already-stamped row is
# never re-written (Pedro's manual `--allow-overwrite` stays authoritative).
#
# WHY A 242-SIDE POLLER, NOT A GITHUB ACTION (the three reasons PET-191/the runbook gave
# for rejecting a merge-triggered Action — a poller satisfies all three):
#   1. Worker PRs live in the Co-latro app repos, so an Action would be duplicated into each
#      → this single host polls every repo from one place.
#   2. A merge event can only ever record `merge`, never `kickback` → reading the PR's close
#      state here captures BOTH (mergedAt set vs. closed-unmerged).
#   3. The eval log is a single-operator, serial-writer object with no lock → this stays on
#      the one loop host as the `agent` user, preserving that invariant (see the race note).
#
# RACE NOTE: this is a SECOND automated writer to verdicts.jsonl (the reviewer's append is
# the first). Both do read-modify-write on a lock-free object. They rarely coincide (an
# append happens at review time, a stamp after close), the timer is `oneshot` so it never
# overlaps itself, and the bucket is versioned (the recovery net). Keep the cadence modest.
# If a true concurrent-writer regime ever appears, this needs a real lock — same caveat the
# append/stamp scripts already carry.
#
# READ from GitHub is read-only (`gh pr list`); the only WRITE is delegated to
# `reviewer-stamp-pedro-verdict.sh`, which writes the MinIO object via `mc`. This script
# never merges, comments, pushes, or mutates Linear.
#
# Usage:
#   scripts/reviewer/reviewer-stamp-poll.sh [--dry-run]
#
# Env (optional):
#   REVIEWER_REPOS          space-separated owner/repo list to poll
#                           (default: PeteDio-Labs/co-latro-backend
#                                     PeteDio-Labs/co-latro-frontend)
#   REVIEWER_CLOSED_LIMIT   how many recently-closed PRs to scan per repo (default: 50)
#   REVIEWER_MC_ALIAS       mc alias for the homelab MinIO (default: homelab)
#   REVIEWER_VERDICTS_PATH  bucket/key for the log (default: agent-evals/verdicts.jsonl)
#   GH_TOKEN                read scope. If unset, the petedio-reviewer[bot] App token is
#                           minted via reviewer-mint-token.sh (contents:read + pr:write — read
#                           is all that's needed; the stamp write is mc→MinIO). Never printed.
set -euo pipefail

die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
info() { printf '\033[1;34m%s\033[0m\n' "$*" >&2; }

DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

for t in gh mc python3; do command -v "$t" >/dev/null || die "$t not in PATH."; done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$SCRIPT_DIR/reviewer-stamp-pedro-verdict.sh"
[ -x "$STAMP" ] || [ -f "$STAMP" ] || die "stamp script not found at $STAMP."

REPOS="${REVIEWER_REPOS:-PeteDio-Labs/co-latro-backend PeteDio-Labs/co-latro-frontend}"
CLOSED_LIMIT="${REVIEWER_CLOSED_LIMIT:-50}"
ALIAS="${REVIEWER_MC_ALIAS:-homelab}"
VPATH="${REVIEWER_VERDICTS_PATH:-agent-evals/verdicts.jsonl}"
TARGET="${ALIAS}/${VPATH}"

# --- token (never printed) — env first, else mint the reviewer[bot] App token -----------
# kv/services/agent-loop holds NO plain github_token: the bots are GitHub Apps (PET-176), so
# the secret is reviewer_app_id/pem, not a PAT. Mint the reviewer installation token (scope:
# contents:read + pr:write) — read is all the poller needs from gh; the stamp WRITE goes to
# MinIO via mc, not gh. reviewer-mint-token.sh self-serves its Vault auth (Agent token on
# disk, VAULT_ADDR/CACERT defaulted). (242 test run caught the old github_token read failing.)
if [ -z "${GH_TOKEN:-}" ]; then
  GH_TOKEN="$("$SCRIPT_DIR/reviewer-mint-token.sh" 2>/dev/null || true)"
  export GH_TOKEN
fi
[ -n "${GH_TOKEN:-}" ] || die "could not mint the petedio-reviewer[bot] token (reviewer-mint-token.sh; Vault Agent token present?)."

mc alias list "$ALIAS" >/dev/null 2>&1 ||
  die "mc alias '$ALIAS' not configured. Seed it from Vault kv/services/agent-loop (see docs/runbooks/reviewer-loop.md)."

# --- the verdict log: find rows still missing a pedro_verdict ----------------------------
if ! mc stat "$TARGET" >/dev/null 2>&1; then
  info "no verdict log at $TARGET yet — nothing to stamp."
  exit 0
fi
LOG="$(mc cat "$TARGET" 2>/dev/null)" || die "could not read $TARGET."

# Emit "issue<TAB>pr" for every row whose pedro_verdict is empty. Bad lines are skipped, not
# fatal (the reviewer's append is the source of truth; a corrupt line is a separate problem).
# Data is passed via an env var (not piped) so the heredoc — which is python's PROGRAM on
# stdin — can't collide with it (same env-var pattern as reviewer-log-verdict.sh).
UNSTAMPED="$(
  VERDICT_LOG="$LOG" python3 <<'PY'
import json, os
seen = set()
out = []
for line in os.environ["VERDICT_LOG"].splitlines():
    line = line.strip()
    if not line:
        continue
    try:
        row = json.loads(line)
    except json.JSONDecodeError:
        continue
    if (row.get("pedro_verdict") or "") != "":
        continue
    issue = str(row.get("issue") or "")
    pr = str(row.get("pr") or "")
    if not issue or not pr:
        continue
    key = (issue, pr)
    if key in seen:
        continue
    seen.add(key)
    out.append(f"{issue}\t{pr}")
print("\n".join(out))
PY
)"

if [ -z "$UNSTAMPED" ]; then
  info "every verdict row already has a pedro_verdict — nothing to stamp."
  exit 0
fi

# --- match each unstamped row to a closed PR's final state ------------------------------
# Gather recently-closed PRs (number, merged?, PET key) across the repos, then ask python to
# join them to the unstamped set and decide merge|kickback. Output: "issue<TAB>pr<TAB>verdict".
CLOSED=""
for repo in $REPOS; do
  pr_json="$(gh pr list --repo "$repo" --state closed --limit "$CLOSED_LIMIT" \
    --json number,mergedAt,headRefName,title 2>/dev/null)" || {
    info "gh pr list (closed) failed for $repo — skipping it this run."
    continue
  }
  CLOSED+="${repo}"$'\t'"${pr_json}"$'\n'
done

# Both inputs via env vars — see the note above. gh's `--json` (piped, not a TTY) emits one
# compact line per repo, so the "repo<TAB>json" line parse holds (same as reviewer-candidates.sh).
ACTIONS="$(
  UNSTAMPED="$UNSTAMPED" CLOSED="$CLOSED" python3 <<'PY'
import json, os, re

PET = re.compile(r"PET-(\d+)", re.IGNORECASE)

# unstamped: {(issue, pr): True}
unstamped = {}
for line in os.environ["UNSTAMPED"].splitlines():
    if not line.strip():
        continue
    issue, _, pr = line.partition("\t")
    unstamped[(issue.strip(), pr.strip())] = True

actions = {}  # (issue, pr) -> verdict, dedup across repos
for line in os.environ["CLOSED"].splitlines():
    if not line.strip():
        continue
    repo, _, payload = line.partition("\t")
    try:
        prs = json.loads(payload) if payload.strip() else []
    except json.JSONDecodeError:
        continue
    for pr in prs:
        num = str(pr.get("number") or "")
        m = PET.search(pr.get("headRefName", "") or "") or PET.search(pr.get("title", "") or "")
        if not m or not num:
            continue
        issue = "PET-" + m.group(1)
        key = (issue, num)
        if key not in unstamped or key in actions:
            continue
        actions[key] = "merge" if pr.get("mergedAt") else "kickback"

for (issue, num), verdict in actions.items():
    print(f"{issue}\t{num}\t{verdict}")
PY
)"

if [ -z "$ACTIONS" ]; then
  info "no unstamped verdict row maps to a closed PR yet — nothing to do."
  exit 0
fi

# --- stamp each matched row (delegated to the PET-191 writer) ----------------------------
stamped=0 failed=0
while IFS=$'\t' read -r issue pr verdict; do
  [ -n "$issue" ] || continue
  if [ "$DRY_RUN" = true ]; then
    info "would stamp $issue (PR $pr) -> $verdict"
    stamped=$((stamped + 1))
    continue
  fi
  if bash "$STAMP" --issue "$issue" --pr "$pr" --verdict "$verdict" >/dev/null 2>&1; then
    info "stamped $issue (PR $pr) -> $verdict"
    stamped=$((stamped + 1))
  else
    info "stamp FAILED for $issue (PR $pr) -> $verdict (ambiguous match? run by hand)."
    failed=$((failed + 1))
  fi
done <<<"$ACTIONS"

info "done: stamped=$stamped failed=$failed (dry-run=$DRY_RUN)"
