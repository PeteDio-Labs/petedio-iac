#!/usr/bin/env bash
#
# actions-approve-off.sh — turn off "Allow GitHub Actions to create and approve
# pull requests" for the organisation, then read every repo back. PET-458.
#
# WHY THIS SETTING. A required review is the one control PET-399 rests on, and in
# an org of one it works only because GitHub forbids approving your own pull
# request. A workflow with `pull-requests: write` can approve on the org's behalf,
# which walks around that. PET-412 found it and closed it on petedio-iac alone;
# it is open on 32 of the other 36 repos, including every repo that deploys to a
# live host on push.
#
# WHY IT MATTERS MORE THAN BRANCH PROTECTION HERE. PeteDio-Labs is on the Free
# plan, so `/branches/main/protection` and `/rulesets` answer 403 on all 13
# private repos (PET-457, docs/GOTCHAS.md). This endpoint answers 200 on every
# repo, public and private alike. It is the only gate available org-wide.
#
# Usage:
#   ./scripts/actions-approve-off.sh            # read-only: what is set, what would change
#   ./scripts/actions-approve-off.sh --apply    # make the change, then read it back
#
# Needs `gh` authenticated with admin scope on the org. Without --apply the script
# issues no PUT and changes nothing.
#
# ⚠ BOTH FIELDS GO IN EVERY PUT. /actions/permissions/workflow takes
#   default_workflow_permissions and can_approve_pull_request_reviews together.
#   Sending one is a request to replace the object, and the field left out does not
#   keep its value by being unmentioned — that is how PET-418 lost two required
#   contexts from petedio-iac's protection for eleven days. Every PUT below reads
#   the current object first and re-sends default_workflow_permissions verbatim.
set -uo pipefail

ORG="${ORG:-PeteDio-Labs}"
APPLY=0
[ "${1-}" = "--apply" ] && APPLY=1

command -v gh >/dev/null 2>&1 || { echo "FATAL: gh not found on PATH" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq not found on PATH" >&2; exit 1; }

c_b=$'\033[1m'; c_g=$'\033[32m'; c_y=$'\033[33m'; c_r=$'\033[31m'; c_d=$'\033[2m'; c_0=$'\033[0m'
CHANGED=0; ALREADY=0; FAILED=0; UNREAD=0

sec() { printf '\n%s%s%s\n' "$c_b" "$1" "$c_0"; }

# Read one /actions/permissions/workflow object. Sets WF_STATUS, WF_APPROVE and
# WF_PERMS. The status is kept because a repo that cannot be read must be reported
# as unread, never as compliant — a gate that silently covers nothing is the whole
# subject of PET-418.
read_wf() {
  local out
  out="$(gh api -i "$1" 2>/dev/null)"
  WF_STATUS="$(printf '%s' "$out" | head -1 | awk '{print $2}')"
  local body
  body="$(printf '%s' "$out" | awk 'b {print} /^\r?$/ {b=1}')"
  # ⚠ NOT `// "?"`. jq's alternative operator fires on false as well as null, so
  #   `.can_approve_pull_request_reviews // "?"` turns every already-compliant repo
  #   into an unknown. The first draft of this script did exactly that and reported
  #   the four repos PET-412 had already fixed as needing the change. On a boolean,
  #   ask whether the key is present; never lean on `//`.
  WF_APPROVE="$(printf '%s' "$body" | jq -r 'if has("can_approve_pull_request_reviews") then (.can_approve_pull_request_reviews|tostring) else "?" end' 2>/dev/null)"
  WF_PERMS="$(printf '%s' "$body" | jq -r 'if has("default_workflow_permissions") then (.default_workflow_permissions|tostring) else "?" end' 2>/dev/null)"
  [ -n "$WF_STATUS" ] || WF_STATUS="000"
}

# Turn approval off at $1, preserving default_workflow_permissions as read.
turn_off() {
  local path="$1" perms="$2"
  gh api -X PUT "$path" \
    -f "default_workflow_permissions=$perms" \
    -F "can_approve_pull_request_reviews=false" >/dev/null 2>&1
}

sec "Organisation: $ORG"
read_wf "/orgs/$ORG/actions/permissions/workflow"
if [ "$WF_STATUS" != "200" ]; then
  echo "  ${c_r}✗${c_0} could not read the org setting (HTTP $WF_STATUS) — needs admin:org"
  exit 1
fi
echo "  default_workflow_permissions   $WF_PERMS"
echo "  can_approve_pull_request_reviews  $WF_APPROVE"

if [ "$WF_APPROVE" = "false" ]; then
  echo "  ${c_g}✓${c_0} already off at the org level"
elif [ "$APPLY" -eq 1 ]; then
  if turn_off "/orgs/$ORG/actions/permissions/workflow" "$WF_PERMS"; then
    read_wf "/orgs/$ORG/actions/permissions/workflow"
    if [ "$WF_APPROVE" = "false" ] && [ "$WF_PERMS" != "?" ]; then
      echo "  ${c_g}✓${c_0} turned off; default_workflow_permissions still $WF_PERMS"
    else
      echo "  ${c_r}✗${c_0} the PUT returned success but the read-back says approve=$WF_APPROVE perms=$WF_PERMS"
      FAILED=$((FAILED + 1))
    fi
  else
    echo "  ${c_r}✗${c_0} the PUT failed"
    FAILED=$((FAILED + 1))
  fi
else
  echo "  ${c_y}would turn off${c_0} (re-run with --apply)"
fi

# The org setting caps every repo, but a repo keeps its own stored value, and that
# is what /repos/.../actions/permissions/workflow reports. Leaving 32 repos storing
# `true` means the hole reopens the day the org cap is lifted, and the PET-457
# read-back table can only hold a repo at a value the repo actually stores. So set
# each one as well, rather than trusting the cap alone.
sec "Repositories, one line each"
REPOS="$(gh api "/orgs/$ORG/repos" --paginate --jq '.[] | select(.archived|not) | .name' 2>/dev/null | sort)"
[ -n "$REPOS" ] || { echo "  ${c_r}✗${c_0} could not list the org's repos"; exit 1; }

for repo in $REPOS; do
  read_wf "/repos/$ORG/$repo/actions/permissions/workflow"
  case "$WF_STATUS" in
    200) : ;;
    *)   printf '  %s-%s %-24s could not read the setting (HTTP %s)\n' "$c_y" "$c_0" "$repo" "$WF_STATUS"
         UNREAD=$((UNREAD + 1)); continue ;;
  esac

  if [ "$WF_APPROVE" = "false" ]; then
    printf '  %s✓%s %-24s already false\n' "$c_g" "$c_0" "$repo"
    ALREADY=$((ALREADY + 1))
  elif [ "$WF_PERMS" = "?" ]; then
    printf '  %s-%s %-24s read back no default_workflow_permissions — skipped, a PUT would guess it\n' "$c_y" "$c_0" "$repo"
    UNREAD=$((UNREAD + 1))
  elif [ "$APPLY" -eq 0 ]; then
    printf '  %s~%s %-24s approve=%s perms=%s — would set false\n' "$c_y" "$c_0" "$repo" "$WF_APPROVE" "$WF_PERMS"
    CHANGED=$((CHANGED + 1))
  else
    if turn_off "/repos/$ORG/$repo/actions/permissions/workflow" "$WF_PERMS"; then
      # Read back rather than trusting the 204. The whole point of this script is
      # that a setting which reports success and did not take is the failure mode.
      read_wf "/repos/$ORG/$repo/actions/permissions/workflow"
      if [ "$WF_APPROVE" = "false" ]; then
        printf '  %s✓%s %-24s set false (perms still %s)\n' "$c_g" "$c_0" "$repo" "$WF_PERMS"
        CHANGED=$((CHANGED + 1))
      else
        printf '  %s✗%s %-24s PUT succeeded, read-back still says %s\n' "$c_r" "$c_0" "$repo" "$WF_APPROVE"
        FAILED=$((FAILED + 1))
      fi
    else
      printf '  %s✗%s %-24s PUT failed\n' "$c_r" "$c_0" "$repo"
      FAILED=$((FAILED + 1))
    fi
  fi
done

sec "Summary"
if [ "$APPLY" -eq 0 ]; then
  printf '%s%d would change, %d already false, %d unreadable%s\n' "$c_b" "$CHANGED" "$ALREADY" "$UNREAD" "$c_0"
  printf '%sread-only: no PUT was issued. Re-run with --apply to make the change.%s\n' "$c_d" "$c_0"
else
  printf '%s%d changed, %d already false, %d failed, %d unreadable%s\n' "$c_b" "$CHANGED" "$ALREADY" "$FAILED" "$UNREAD" "$c_0"
  printf '%sNext: flip the approve column of the declared table in repo-protection-verify.sh\n'
  printf 'from ? to false, so a repo that drifts back fails that check (PET-457).%s\n' "$c_d$c_0"
fi
[ "$FAILED" -eq 0 ] || exit 1
