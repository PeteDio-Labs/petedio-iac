#!/usr/bin/env bash
# rebase-loop-prs.sh — keep the loop's own open PRs rebased on main (PET-148).
#
# Loop PRs share a base sha; every merge leaves the rest behind, and a stale PR's
# plan-on-PR no longer reflects what merging it would actually do (PR #46 sat behind 5
# merges). This rebases the loop's OWN open branches onto the current main and force-
# pushes them, which re-triggers plan-on-PR so Pedro always reviews a fresh plan. Run by a
# systemd timer on agent-loop-242 (roles/agent-loop) — "within the cron interval" per the
# AC — or by hand.
#
# SAFETY — force-push is restricted to loop branches by TWO independent guards, both must
# hold for a branch to be touched (a human branch is never force-pushed):
#   (1) the PR's head branch matches the loop prefix (default ^pet-), AND
#   (2) the PR's author is the loop's own GitHub account (`gh api user`).
# It also only ever operates in a throwaway /tmp clone — never the loop's live working
# tree — and uses --force-with-lease (won't clobber a branch that moved since we fetched).
#
# RE-TRIGGER: pushes made with the loop's PAT (GH_TOKEN below) DO start a new
# `pull_request` run; a push with the Actions GITHUB_TOKEN would not — which is why this is
# a 242-side job using the loop token, not a GitHub Actions workflow.
#
# Usage:
#   scripts/rebase-loop-prs.sh [--dry-run]
#
# Env (optional):
#   REBASE_REPO        owner/repo to operate on (default: PeteDio-Labs/petedio-iac)
#   REBASE_BRANCH_RE   egrep branch guard (default: ^pet-)
#   REBASE_BASE        base branch to rebase onto (default: main)
#   GH_TOKEN           loop PAT (push + open-PR scope). If unset, read from Vault
#                      kv/services/agent-loop field github_token (same pattern as
#                      scripts/proxmox-ro-config.sh). Never printed.
set -euo pipefail

die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
info() { printf '\033[1;34m%s\033[0m\n' "$*" >&2; }

DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

for t in gh git python3; do command -v "$t" >/dev/null || die "$t not in PATH."; done

REPO="${REBASE_REPO:-PeteDio-Labs/petedio-iac}"
BRANCH_RE="${REBASE_BRANCH_RE:-^pet-}"
BASE="${REBASE_BASE:-main}"

# --- token (never printed) — env first, else Vault, mirroring proxmox-ro-config.sh ---
if [ -z "${GH_TOKEN:-}" ]; then
  command -v vault >/dev/null || die "GH_TOKEN unset and vault not in PATH."
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
  export VAULT_CACERT="${VAULT_CACERT:-$SCRIPT_DIR/../environments/homelab/vault-ca.crt}"
  GH_TOKEN="$(vault kv get -field=github_token kv/services/agent-loop 2>/dev/null)" ||
    die "could not read github_token from kv/services/agent-loop (Vault Agent token present?)."
  export GH_TOKEN
fi
[ -n "${GH_TOKEN:-}" ] || die "empty GH_TOKEN."

# Whose PRs are "ours" — the second guard. Resolve once.
SELF="$(gh api user --jq .login 2>/dev/null)" || die "gh api user failed (token valid?)."
[ -n "$SELF" ] || die "could not resolve the loop's own GitHub login."
info "repo=$REPO base=$BASE guard: head =~ $BRANCH_RE AND author == $SELF  (dry-run=$DRY_RUN)"

# Eligible PRs: open, base == $BASE, head matches the prefix, authored by us. The branch +
# author filter is applied here in python so the guard is in exactly one auditable place.
PRS_JSON="$(gh pr list --repo "$REPO" --state open --base "$BASE" --limit 100 \
  --json number,headRefName,author,baseRefName,isDraft 2>/dev/null)" ||
  die "gh pr list failed for $REPO."

mapfile -t BRANCHES < <(
  REBASE_SELF="$SELF" REBASE_BRANCH_RE="$BRANCH_RE" python3 - "$PRS_JSON" <<'PY'
import json, os, re, sys
prs = json.loads(sys.argv[1] or "[]")
self_login = os.environ["REBASE_SELF"]
rx = re.compile(os.environ["REBASE_BRANCH_RE"])
for pr in prs:
    head = pr.get("headRefName", "") or ""
    author = (pr.get("author") or {}).get("login", "") or ""
    # BOTH guards — a branch missing either is silently left alone.
    if rx.search(head) and author == self_login:
        print(f"{pr['number']}\t{head}")
PY
)

if [ "${#BRANCHES[@]}" -eq 0 ]; then
  info "no eligible loop PRs to rebase."
  exit 0
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/rebase-loop-XXXXXX")"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

# Fresh clone in /tmp — NEVER the loop's live working tree (which may be mid-iteration).
# gh sets up the authenticated remote; full history (no --depth) so rebases resolve.
gh repo clone "$REPO" "$WORKDIR/repo" >/dev/null 2>&1 || die "clone of $REPO failed."
cd "$WORKDIR/repo"
git config user.name "agent-loop" >/dev/null 2>&1 || true
git config user.email "agent-loop@petedio.local" >/dev/null 2>&1 || true
git fetch --quiet origin "$BASE"

rebased=0 skipped=0 conflicted=0
for entry in "${BRANCHES[@]}"; do
  num="${entry%%$'\t'*}"
  br="${entry#*$'\t'}"

  # Belt-and-suspenders: re-assert the branch guard right before any write. If the prefix
  # somehow doesn't match here, refuse — we must never force-push a non-loop branch.
  if ! printf '%s' "$br" | grep -Eq "$BRANCH_RE"; then
    info "PR #$num ($br): branch guard failed at push time — refusing, skipping."
    skipped=$((skipped + 1))
    continue
  fi

  git fetch --quiet origin "$br" || { info "PR #$num ($br): fetch failed, skipping."; skipped=$((skipped + 1)); continue; }
  git checkout -q -B "$br" "origin/$br"

  # Already contains the tip of base? Then it's up to date — nothing to do.
  if git merge-base --is-ancestor "origin/$BASE" HEAD; then
    info "PR #$num ($br): already up to date with $BASE."
    skipped=$((skipped + 1))
    continue
  fi

  if ! git rebase --quiet "origin/$BASE"; then
    git rebase --abort || true
    info "PR #$num ($br): rebase hit conflicts — leaving as-is for a manual rebase."
    conflicted=$((conflicted + 1))
    continue
  fi

  if [ "$DRY_RUN" = true ]; then
    info "PR #$num ($br): would force-push (rebased onto $BASE)."
    rebased=$((rebased + 1))
    continue
  fi

  # --force-with-lease pinned to the sha we fetched: aborts if the branch moved underneath
  # us (e.g. the worker pushed) instead of clobbering it.
  if git push --quiet --force-with-lease="$br:origin/$br" origin "HEAD:$br"; then
    info "PR #$num ($br): rebased onto $BASE and force-pushed (plan-on-PR re-triggered)."
    rebased=$((rebased + 1))
  else
    info "PR #$num ($br): force-push rejected (branch moved since fetch?) — skipping."
    skipped=$((skipped + 1))
  fi
done

info "done: rebased=$rebased skipped=$skipped conflicted=$conflicted"
