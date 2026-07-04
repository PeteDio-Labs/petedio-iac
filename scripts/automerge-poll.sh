#!/usr/bin/env bash
# automerge-poll.sh — auto-merge Bucket-A worker PRs that pass every gate (PET-185).
#
# Workflow decision (2026-06-25, PET-185): trivial ADDITIVE worker PRs auto-merge;
# engine/logic PRs stay human-merge. This is the merge gate — a 242-side poller (same
# shape + reasons as reviewer-stamp-poll.sh: one host covers every repo, reads both
# outcomes, keeps the serial-writer invariant) instead of GitHub-native auto-merge or a
# per-repo Action, because the Bucket-A predicate reads the MinIO eval logs, which
# GitHub's native rules can't see.
#
# THE PREDICATE — a PR merges ONLY when ALL of these hold (each one is defense in depth):
#   1. open, non-draft, in an AUTOMERGE_REPOS repo
#   2. authored by an allow-listed worker identity (AUTOMERGE_AUTHORS)
#   3. no needs-human / changes-requested label
#   4. the LATEST verdicts.jsonl row for its (issue, pr) is claude_verdict=approve
#      (a later "changes" row vetoes; no verdict row = not reviewed = no merge)
#   5. the worker-runs.jsonl row for (issue, pr) has guard=ok AND its head_sha prefixes
#      the PR's CURRENT head oid (the guard ran on exactly what we'd merge — a pushed-
#      after-guard PR is stale and skipped)
#   6. every check on the head is SUCCESS and the required check (AUTOMERGE_REQUIRED_CHECK)
#      is among them (zero checks is NOT green)
#   7. every changed file matches AUTOMERGE_PATH_RE (per-file catalog adds, PET-216 layout:
#      src/engine/<cat>/…) — anything touching run.ts/engine logic stays human-merge
#
# MERGE IDENTITY (hard rule: the REVIEWER must NEVER merge; the worker App structurally
# CANNOT merge — push+open-PR scope only). This uses, in order:
#   AUTOMERGE_GH_TOKEN env  →  scripts/agent-mint-token.sh merge (a dedicated
#   petedio-merge[bot] App: contents:write + pull_requests:write on the Co-latro repos,
#   seeded once as merge_app_id/merge_pem in Vault kv/services/agent-loop)  →  the host
#   login's own `gh auth token`. It never falls back to the reviewer's minter, and it
#   refuses to run if the resolved identity IS the reviewer (when the identity is
#   introspectable; App installation tokens can't call /user, so for those the guard is
#   "this script never mints via reviewer-mint-token.sh" + the App's own scopes).
#
# WRITES: `gh pr merge --squash --delete-branch` (verified back via mergedAt) and one
# `agent-event.sh --agent loop --event auto_merged` row per merge. pedro_verdict is NOT
# stamped here — reviewer-stamp-poll.sh picks the merged PR up on its next tick and stamps
# `merge`, same as a manual Pedro merge (an auto-merge IS an accepted verdict for the eval).
#
# Usage:
#   scripts/automerge-poll.sh [--dry-run]      # dry-run: full predicate, prints WOULD-MERGE
#
# Env (all optional):
#   AUTOMERGE_REPOS           space-separated owner/repo list
#                             (default: PeteDio-Labs/co-latro-backend)
#   AUTOMERGE_AUTHORS         space-separated author logins allowed to auto-merge
#                             (default: "petedio-worker[bot] app/petedio-worker")
#   AUTOMERGE_REQUIRED_CHECK  check name that must be present + green (default: build)
#   AUTOMERGE_PATH_RE         python regex every changed path must match (default: the
#                             PET-216 per-file catalog dirs + their tests, see below)
#   AUTOMERGE_MAX_PER_RUN     merge at most N PRs per tick (default: 2 — modest on purpose)
#   AUTOMERGE_BLOCK_LABELS    labels that veto (default: "needs-human changes-requested")
#   AUTOMERGE_REVIEWER_LOGIN  identity that must never be the merger
#                             (default: "petedio-reviewer[bot]")
#   AUTOMERGE_MC_ALIAS / AUTOMERGE_EVALS_PREFIX   MinIO alias + bucket prefix
#                             (defaults: homelab / agent-evals)
#
# Exit 0 always on a clean poll (incl. nothing to do); non-zero only on a real error.
set -euo pipefail

die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
info() { printf '\033[1;34m%s\033[0m\n' "$*" >&2; }

DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

for t in gh mc python3; do command -v "$t" >/dev/null || die "$t not in PATH."; done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVENT="$SCRIPT_DIR/agent-event.sh"

REPOS="${AUTOMERGE_REPOS:-PeteDio-Labs/co-latro-backend}"
AUTHORS="${AUTOMERGE_AUTHORS:-petedio-worker[bot] app/petedio-worker}"
REQUIRED_CHECK="${AUTOMERGE_REQUIRED_CHECK:-build}"
PATH_RE="${AUTOMERGE_PATH_RE:-^src/engine/(jokers|consumables|tags|vouchers)/[^/]+\.ts$|^src/[^/]+\.test\.ts$}"
MAX_PER_RUN="${AUTOMERGE_MAX_PER_RUN:-2}"
BLOCK_LABELS="${AUTOMERGE_BLOCK_LABELS:-needs-human changes-requested}"
REVIEWER_LOGIN="${AUTOMERGE_REVIEWER_LOGIN:-petedio-reviewer[bot]}"
ALIAS="${AUTOMERGE_MC_ALIAS:-homelab}"
PREFIX="${AUTOMERGE_EVALS_PREFIX:-agent-evals}"

# --- merge token: env -> petedio-merge[bot] App -> host login. NEVER the reviewer. ------
if [ -z "${AUTOMERGE_GH_TOKEN:-}" ]; then
  AUTOMERGE_GH_TOKEN="$("$SCRIPT_DIR/agent-mint-token.sh" merge 2>/dev/null || true)"
fi
if [ -z "${AUTOMERGE_GH_TOKEN:-}" ]; then
  AUTOMERGE_GH_TOKEN="$(gh auth token 2>/dev/null || true)"
  # Introspectable identity (PATs only): refuse to be the reviewer.
  if [ -n "$AUTOMERGE_GH_TOKEN" ]; then
    LOGIN="$(GH_TOKEN="$AUTOMERGE_GH_TOKEN" gh api user --jq .login 2>/dev/null || true)"
    [ "$LOGIN" = "$REVIEWER_LOGIN" ] && die "merge token resolves to the reviewer ($LOGIN) — the reviewer must never merge."
  fi
fi
[ -n "${AUTOMERGE_GH_TOKEN:-}" ] || die "no merge token: set AUTOMERGE_GH_TOKEN, seed the petedio-merge[bot] App (merge_app_id/merge_pem in kv/services/agent-loop), or gh-auth the host login."

mc alias list "$ALIAS" >/dev/null 2>&1 || die "mc alias '$ALIAS' not configured (see docs/runbooks/reviewer-loop.md)."

# --- eval logs (read once per tick) ------------------------------------------------------
VERDICTS="$(mc cat "$ALIAS/$PREFIX/verdicts.jsonl" 2>/dev/null || true)"
WORKER_RUNS="$(mc cat "$ALIAS/$PREFIX/worker-runs.jsonl" 2>/dev/null || true)"
[ -n "$VERDICTS" ] || { info "no verdicts log — nothing can be approved; done."; exit 0; }

merged=0
for repo in $REPOS; do
  [ "$merged" -ge "$MAX_PER_RUN" ] && break
  PRS="$(GH_TOKEN="$AUTOMERGE_GH_TOKEN" gh pr list --repo "$repo" --state open --limit 50 \
        --json number,title,author,isDraft,labels,headRefOid,headRefName 2>/dev/null || echo '[]')"

  # One python pass applies gates 1–5 from local data; gates 6–7 need per-PR gh calls.
  CANDIDATES="$(
    PRS_JSON="$PRS" VERDICT_LOG="$VERDICTS" RUNS_LOG="$WORKER_RUNS" \
    AUTHORS="$AUTHORS" BLOCK_LABELS="$BLOCK_LABELS" python3 <<'PY'
import json, os, re
prs = json.loads(os.environ["PRS_JSON"])
authors = set(os.environ["AUTHORS"].split())
block = set(os.environ["BLOCK_LABELS"].split())

def rows(env):
    for line in os.environ.get(env, "").splitlines():
        line = line.strip()
        if not line: continue
        try: yield json.loads(line)
        except json.JSONDecodeError: continue

# latest verdict per (issue, pr) — a later "changes" row vetoes an earlier approve
latest = {}
for r in rows("VERDICT_LOG"):
    key = (str(r.get("issue") or ""), str(r.get("pr") or ""))
    if key[0] and key[1] and str(r.get("ts") or "") >= str(latest.get(key, {}).get("ts") or ""):
        latest[key] = r

# guard-ok head shas per (issue, pr)
guards = {}
for r in rows("RUNS_LOG"):
    key = (str(r.get("issue") or ""), str(r.get("pr") or ""))
    if key[0] and key[1] and str(r.get("guard") or "") == "ok":
        guards.setdefault(key, set()).add(str(r.get("head_sha") or ""))

pet_re = re.compile(r"[Pp][Ee][Tt]-(\d+)")
out = []
for pr in prs:
    if pr.get("isDraft"): continue
    if (pr.get("author") or {}).get("login") not in authors: continue
    if block & {l.get("name") for l in (pr.get("labels") or [])}: continue
    m = pet_re.search(pr.get("headRefName") or "") or pet_re.search(pr.get("title") or "")
    if not m: continue
    key = (f"PET-{m.group(1)}", str(pr["number"]))
    v = latest.get(key)
    if not v or str(v.get("claude_verdict") or "") != "approve": continue
    head = str(pr.get("headRefOid") or "")
    if not any(s and head.startswith(s) for s in guards.get(key, ())): continue
    out.append(f'{pr["number"]}\t{key[0]}\t{head}')
print("\n".join(out))
PY
  )"
  [ -n "$CANDIDATES" ] || { info "$repo: no PR passes the local gates."; continue; }

  while IFS=$'\t' read -r num pet head; do
    [ "$merged" -ge "$MAX_PER_RUN" ] && break
    # gate 6 — every check green AND the required one present (zero checks ≠ green)
    CHECKS_OK="$(GH_TOKEN="$AUTOMERGE_GH_TOKEN" gh pr view "$num" --repo "$repo" \
      --json statusCheckRollup --jq \
      "[.statusCheckRollup[]?] | (length > 0)
        and (map(select((.conclusion // .state) != \"SUCCESS\")) | length == 0)
        and (map(.name // .context) | index(\"$REQUIRED_CHECK\") != null)" 2>/dev/null || echo false)"
    [ "$CHECKS_OK" = "true" ] || { info "$repo#$num ($pet): checks not green/complete — skip."; continue; }

    # gate 7 — additive-path allowlist
    PATHS_OK="$(GH_TOKEN="$AUTOMERGE_GH_TOKEN" gh pr diff "$num" --repo "$repo" --name-only 2>/dev/null \
      | PATH_RE="$PATH_RE" python3 -c '
import os, re, sys
rx = re.compile(os.environ["PATH_RE"])
paths = [p for p in sys.stdin.read().splitlines() if p.strip()]
print("true" if paths and all(rx.search(p) for p in paths) else "false")')"
    [ "$PATHS_OK" = "true" ] || { info "$repo#$num ($pet): paths outside the Bucket-A allowlist — human merge."; continue; }

    if $DRY_RUN; then
      info "WOULD-MERGE $repo#$num ($pet) head=$head"
      continue
    fi

    info "auto-merging $repo#$num ($pet)…"
    GH_TOKEN="$AUTOMERGE_GH_TOKEN" gh pr merge "$num" --repo "$repo" --squash --delete-branch ||
      { info "$repo#$num: merge failed — leaving for a human."; continue; }
    # verify — never assert merge state from the attempt alone (PET-146 rule)
    MERGED_AT="$(GH_TOKEN="$AUTOMERGE_GH_TOKEN" gh pr view "$num" --repo "$repo" --json mergedAt --jq .mergedAt 2>/dev/null || true)"
    [ -n "$MERGED_AT" ] && [ "$MERGED_AT" != "null" ] || { info "$repo#$num: merge NOT verified — check by hand."; continue; }
    merged=$((merged + 1))
    "$EVENT" --agent loop --event auto_merged --issue "$pet" --pr "$num" \
      --detail "Bucket-A auto-merge: approve + guard-ok@head + green $REQUIRED_CHECK + additive paths ($repo, $MERGED_AT)" || true
  done <<<"$CANDIDATES"
done

info "done — merged $merged PR(s) this tick."
