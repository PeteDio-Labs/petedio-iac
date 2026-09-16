#!/usr/bin/env bash
# repo-protection-verify — read branch protection back, for every repo in the org.
#
# WHY THIS EXISTS: nothing ever read it back. PET-397 made `ansible-validate` a
# required status check on this repo. A day later an unrelated revert of
# `enforce_admins` re-sent the protection object without the contexts and took it
# out again — branch protection is a full-replacement PUT, so every field you do
# not resend is dropped. Nothing reported it. The job still ran on every pull
# request and still went green, and the runbook still said the check was
# required, for the eight days until PET-418 read the contexts by hand.
#
# That is the shape this script exists to catch: not a check that fails, but a
# gate that quietly stopped being a gate while everything above it kept
# reporting success.
#
#   ./scripts/repo-protection-verify.sh          # full run, one line per repo
#   ./scripts/repo-protection-verify.sh --quiet  # only failures
#
# Needs `gh` authenticated with repo admin scope. Reads only: no PUT, no PATCH.
#
# THE TABLE BELOW IS INTENT, not a snapshot. A row says what protection that repo
# is meant to have; the script reads what it does have and reports the gap. So
# fixing a red line means changing the world OR changing the intent, deliberately
# and in a commit — never by pasting today's live values over the table.
set -uo pipefail

ORG=PeteDio-Labs
QUIET=0; [ "${1:-}" = "--quiet" ] && QUIET=1
PASS=0; FAIL=0; SKIP=0

ok()   { PASS=$((PASS+1)); [ $QUIET -eq 1 ] || printf "  \033[32m✓\033[0m %-24s %s\n" "$1" "${2:-}"; }
bad()  { FAIL=$((FAIL+1)); printf "  \033[31m✗\033[0m %-24s %s\n" "$1" "${2:-}"; }
skip() { SKIP=$((SKIP+1)); [ $QUIET -eq 1 ] || printf "  \033[33m-\033[0m %-24s %s\n" "$1" "${2:-}"; }
sec()  { [ $QUIET -eq 1 ] || printf "\n\033[1m%s\033[0m\n" "$1"; }

# ── The declared table ────────────────────────────────────────────────────────
#
# Three columns: repo, protection intent, and the intended value of that repo's
# `can_approve_pull_request_reviews` Actions setting. Whitespace-separated; `#`
# starts a comment.
#
# The protection column takes one of:
#
#   ctx=a,b reviews=N strict=yes admins=no   the shape main must have. Context
#                                            order does not matter. Every listed
#                                            key is asserted; omit a key to leave
#                                            it unasserted.
#   none                                     main is meant to be unprotected.
#   unavailable                              protection is not purchasable here:
#                                            the repo is private and the org is on
#                                            the Free plan, so both the protection
#                                            and the ruleset APIs answer 403. If it
#                                            ever answers 404 instead, the repo
#                                            became protectable and this row needs
#                                            a decision — the script fails to say so.
#   ?                                        nobody has decided. Reported as a
#                                            visible skip, never as a pass.
#
# The approve column takes `false`, `true` or `?`. It is asserted for every repo,
# protected or not: a workflow that can approve a pull request defeats a required
# review without touching protection at all. PET-458 decides the org-wide answer;
# until then the repos that already read `false` are held there, and the rest are `?`.
#
# WHY SO MANY `?` ROWS: PET-457 is the decision, and it is Pedro's. A row that
# guessed would be a decision made by a script author, recorded as if it had been
# made by an owner. `none` appears only where no deployment reads the repo at all.
read -r -d '' DECLARED <<'TABLE'
# repo                    protection                                    approve
# ── protected today ──────────────────────────────────────────────────────────
petedio-iac               ctx=gate,validate reviews=1 strict=yes admins=no   false
petedio-water-fast        ctx=test reviews=0 strict=yes admins=yes           ?

# ── deploys to a live host on push to main; protection undecided (PET-457) ───
pete-bot                  ?                                                  false
petedio-media-iac         ?                                                  ?
co-latro-admin            unavailable                                        ?
petedio-media-control     unavailable                                        ?
petedio-palworld-panel    unavailable                                        ?

# ── private: protection and rulesets both 403 on the Free plan ───────────────
claude-skills             unavailable                                        ?
fs-mcs-vault              unavailable                                        ?
notification-service      unavailable                                        ?
pete-vision-backend       unavailable                                        ?
pete-vision-desktop       unavailable                                        ?
pete-vision-firmware      unavailable                                        ?
pete-vision-shared        unavailable                                        ?
pete-vision-web           unavailable                                        ?
petedio-vault             unavailable                                        ?
petedio-workspace         unavailable                                        ?

# ── public, no deployment reads them: unprotected on purpose ─────────────────
co-latro-backend          none                                               ?
co-latro-frontend         none                                               ?
code-review-agent         none                                               ?
infra-agent               none                                               ?
job-hunt-app              none                                               ?
knowledge-janitor         none                                               ?
mcp-homelab               none                                               ?
memory-agent              none                                               ?
mission-control-backend   none                                               false
mission-control-mcp       none                                               ?
mission-control-web       none                                               false
ops-investigator          none                                               ?
pete-bot-gitops           none                                               false
petedio-resume-builder    none                                               ?
portfolio                 none                                               ?
portfolio-gitops          none                                               ?
research-agent            none                                               ?
shared                    none                                               ?
web-search-service        none                                               ?
workstation-agent         none                                               ?
TABLE

# ── Live state ────────────────────────────────────────────────────────────────

# Archived repos are excluded: their protection cannot change and their default
# branch is read-only, so a row for one would assert a fact nothing can break.
live_repos() {
  gh api "/orgs/$ORG/repos" --paginate \
    --jq '.[] | select(.archived|not) | [.name, .default_branch] | @tsv' 2>/dev/null | sort
}

# Status code and body in one call. The 403/404 split carries the whole meaning:
# 404 is "could be protected, is not", 403 is "this plan does not sell protection
# for a private repo". Reading only the exit code collapses them into one answer
# and hides an entire class of repo behind a word that sounds deliberate.
api_get() {  # path -> sets API_STATUS, API_BODY
  local out
  out=$(gh api -i "$1" 2>&1)
  API_STATUS=$(printf '%s' "$out" | head -1 | awk '{print $2}')
  API_BODY=$(printf '%s\n' "$out" | awk 'body {print} /^\r?$/ {body=1}')
}

jqf() { printf '%s' "$API_BODY" | jq -r "$1" 2>/dev/null; }

# ── Comparison ────────────────────────────────────────────────────────────────

# Report every difference, not the first. A protection object that lost its
# contexts AND its review count is one event, and seeing half of it sends you
# back for a second run to learn the rest.
check_spec() {  # repo, spec  -> echoes problems, one per line
  local repo="$1" spec="$2" kv key want got
  for kv in $spec; do
    key="${kv%%=*}"; want="${kv#*=}"
    case "$key" in
      ctx)
        got=$(jqf '.required_status_checks.contexts // [] | sort | join(",")')
        want=$(printf '%s' "$want" | tr ',' '\n' | sort | paste -sd, -)
        [ "$got" = "$want" ] || echo "contexts are [$got], declared [$want]"
        ;;
      reviews)
        got=$(jqf '.required_pull_request_reviews.required_approving_review_count // 0')
        [ "$got" = "$want" ] || echo "required reviews $got, declared $want"
        ;;
      strict)
        got=$(jqf 'if .required_status_checks.strict then "yes" else "no" end')
        [ "$got" = "$want" ] || echo "strict (up-to-date) $got, declared $want"
        ;;
      admins)
        got=$(jqf 'if .enforce_admins.enabled then "yes" else "no" end')
        [ "$got" = "$want" ] || echo "enforce_admins $got, declared $want"
        ;;
      *) echo "unknown key '$key' in the declared row for $repo" ;;
    esac
  done
}

# An invariant, not a preference, so it is not in the table: in an org of one,
# `enforce_admins: true` with any required review means NOTHING can ever merge.
# GitHub forbids approving your own pull request, the admin bypass is gone, and
# there is nobody left to ask. That combination deadlocked this repo for an hour
# on 2026-09-12 and left four pull requests unmergeable (PET-399). Whoever
# assembles it next will be adding a review count to a repo that already had
# enforce_admins on, and will not be thinking about the other field.
check_deadlock() {
  local admins reviews
  admins=$(jqf '.enforce_admins.enabled')
  reviews=$(jqf '.required_pull_request_reviews.required_approving_review_count // 0')
  if [ "$admins" = "true" ] && [ "${reviews:-0}" -ge 1 ]; then
    echo "DEADLOCK: enforce_admins=true with $reviews required review(s) — in an org of one nothing can merge (PET-399)"
  fi
}

# ── Run ───────────────────────────────────────────────────────────────────────

sec "Declared table covers the org"
LIVE=$(live_repos)
if [ -z "$LIVE" ]; then
  bad "org repo list" "gh returned nothing — not authenticated, or no network"
  printf "\n\033[1m%d passed, %d failed, %d skipped\033[0m\n" "$PASS" "$FAIL" "$SKIP"
  exit 1
fi
DECLARED_NAMES=$(printf '%s\n' "$DECLARED" | sed 's/#.*//' | awk 'NF {print $1}' | sort)
LIVE_NAMES=$(printf '%s\n' "$LIVE" | cut -f1)

# A repo nobody declared is the failure that let the org grow from 32 repos to 37
# without anyone deciding what the five new ones should enforce. Silence is not a
# decision; make the table refuse to cover a repo it has never heard of.
UNDECLARED=$(comm -23 <(printf '%s\n' "$LIVE_NAMES") <(printf '%s\n' "$DECLARED_NAMES"))
[ -z "$UNDECLARED" ] && ok "every live repo is declared" "$(printf '%s\n' "$LIVE_NAMES" | wc -l | tr -d ' ') repos" \
  || bad "every live repo is declared" "not in the table: $(printf '%s' "$UNDECLARED" | tr '\n' ' ')"

# The other direction: a row for a repo that is gone is a rule protecting nothing,
# and it reads as coverage.
STALE=$(comm -13 <(printf '%s\n' "$LIVE_NAMES") <(printf '%s\n' "$DECLARED_NAMES"))
[ -z "$STALE" ] && ok "no stale rows" \
  || bad "no stale rows" "declared but archived or gone: $(printf '%s' "$STALE" | tr '\n' ' ')"

sec "main branch protection, one line per repo"
while IFS=$'\t' read -r repo branch; do
  row=$(printf '%s\n' "$DECLARED" | sed 's/#.*//' | awk -v r="$repo" '$1 == r')
  [ -n "$row" ] || continue   # already failed above as undeclared
  approve_want=$(printf '%s' "$row" | awk '{print $NF}')
  spec=$(printf '%s' "$row" | awk '{$1=""; $NF=""; sub(/^ +/, ""); sub(/ +$/, ""); print}')
  state=""

  api_get "repos/$ORG/$repo/branches/$branch/protection"
  problems=""

  # Read every display value out of the protection body NOW. The Actions call
  # below overwrites API_BODY, and a summary line rendered after it reads an
  # object with no contexts in it — printing an empty context list next to a
  # green tick. The assertion would still be sound and the line would still be
  # wrong, which is the same shape as a check that reports success and shows
  # nothing.
  live_ctx=$(jqf '.required_status_checks.contexts // [] | join(",")')
  live_reviews=$(jqf '.required_pull_request_reviews.required_approving_review_count // 0')

  case "$spec" in
    '?')
      state=$( [ "$API_STATUS" = "200" ] && echo "protected: ${live_ctx:-no contexts}" \
               || { [ "$API_STATUS" = "403" ] && echo "unprotectable (403)" || echo "unprotected"; } )
      ;;
    unavailable)
      if [ "$API_STATUS" = "403" ]; then state="ok"
      elif [ "$API_STATUS" = "200" ]; then problems="declared unavailable, but main IS protected — the table is stale"
      else problems="declared unavailable, but the API answered $API_STATUS, not 403 — protection became available here and PET-457's decision now applies"
      fi
      ;;
    none)
      if [ "$API_STATUS" = "404" ]; then state="ok"
      elif [ "$API_STATUS" = "200" ]; then problems="declared unprotected, but main IS protected — someone added a rule the table does not record"
      else problems="expected 404 (unprotected), got $API_STATUS"
      fi
      ;;
    *)
      if [ "$API_STATUS" = "200" ]; then
        problems=$(check_spec "$repo" "$spec"; check_deadlock)
      else
        problems="declared protected, but the API answered $API_STATUS — main is NOT protected"
      fi
      ;;
  esac

  # The Actions setting is read for every repo, protected or not.
  api_get "repos/$ORG/$repo/actions/permissions/workflow"
  if [ "$API_STATUS" != "200" ]; then
    # Say "could not ask", never "reads false". An unread setting that defaults to
    # the safe answer is the check reporting a state it never observed.
    approve_got="unread"
    problems="${problems}${problems:+$'\n'}could not read the Actions workflow permissions (HTTP $API_STATUS)"
  else
    approve_got=$(jqf '.can_approve_pull_request_reviews')
    wperm=$(jqf '.default_workflow_permissions')
    if [ "$approve_want" != "?" ] && [ "$approve_got" != "$approve_want" ]; then
      problems="${problems}${problems:+$'\n'}can_approve_pull_request_reviews is $approve_got, declared $approve_want"
    fi
  # Also an invariant rather than a column: a workflow token that can write to the
  # repo by default needs no permission block to push to main. Nothing here asks
  # for it, and every repo reads `read` today.
    if [ -n "$wperm" ] && [ "$wperm" != "read" ] && [ "$wperm" != "null" ]; then
      problems="${problems}${problems:+$'\n'}default_workflow_permissions is $wperm, not read"
    fi
  fi

  if [ -n "$problems" ]; then
    first=1
    while IFS= read -r p; do
      [ $first -eq 1 ] && { bad "$repo" "$p"; first=0; } || printf "    %-24s %s\n" "" "$p"
    done <<< "$problems"
  elif [ "$spec" = "?" ]; then
    skip "$repo" "protection undecided (PET-457) — live: $state, approve=$approve_got"
  else
    case "$spec" in
      none)        ok "$repo" "unprotected, as declared" ;;
      unavailable) skip "$repo" "private on the Free plan — protection and rulesets both 403" ;;
      *)           ok "$repo" "${live_ctx:-no contexts}, $live_reviews review(s)" ;;
    esac
  fi
done <<< "$LIVE"

printf "\n\033[1m%d passed, %d failed, %d skipped\033[0m\n" "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
