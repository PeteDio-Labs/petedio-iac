#!/usr/bin/env bash
# test-repo-protection-verify — feed the comparison recorded protection objects.
#
# WHY: the invariant that matters most in repo-protection-verify.sh cannot fire
# against any repo that exists. `enforce_admins: true` with a required review is
# the combination that deadlocked petedio-iac for an hour on 2026-09-12 (PET-399),
# and no repo in the org carries it today — which is the point. Logic that only a
# live system can reach is logic nobody executes: PET-456 found exactly that in
# the media-lifecycle guards, where a correct three-state classification sat
# between two I/O tasks and had never once run.
#
# So the comparison is fed recorded answers here, including the ones GitHub will
# not produce on demand.
#
#   ./scripts/test-repo-protection-verify.sh
#
# Contacts nothing. No gh, no network, no token.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET="$HERE/repo-protection-verify.sh"
PASS=0; FAIL=0

# Test the shipped functions, not a copy of them. A copy drifts, and a test that
# passes against last week's logic is worse than no test.
#
# ⚠ A `sed -n '/^fn()/,/^}/p'` range cannot do this. `jqf` is a one-liner, so its
# range runs from its own line to the NEXT line starting with `}` — the close of
# a later function — and swallows everything between. The eval then fails on a
# fragment. End the range on the start line itself when that line already closes.
lift() {  # function name -> its definition, exactly as the target file has it
  awk -v fn="$1" '
    index($0, fn "()") == 1 && !started { started=1; print; if ($0 ~ /\}[[:space:]]*$/) exit; next }
    started { print; if ($0 ~ /^\}/) exit }
  ' "$TARGET"
}
for fn in jqf check_spec check_deadlock; do
  eval "$(lift "$fn")"
  declare -F "$fn" >/dev/null || { echo "::error:: could not lift $fn out of $TARGET — the extraction is stale"; exit 1; }
done

# want is a regex; an empty want asserts the check found nothing to report.
case_() {  # name, body, spec, want
  local name="$1" spec="$3" want="$4" got
  API_BODY="$2"
  got=$( { [ -n "$spec" ] && check_spec "test-repo" "$spec"; check_deadlock; } | paste -sd'; ' - )
  if { [ -z "$want" ] && [ -z "$got" ]; } || { [ -n "$want" ] && printf '%s' "$got" | grep -qE "$want"; }; then
    PASS=$((PASS+1)); printf "  \033[32m✓\033[0m %s\n      %s\n" "$name" "${got:-(no findings, as expected)}"
  else
    FAIL=$((FAIL+1)); printf "  \033[31m✗\033[0m %s\n      got:  %s\n      want: %s\n" "$name" "${got:-(nothing)}" "$want"
  fi
}

prot() {  # contexts-json, strict, reviews, enforce_admins
  printf '{"required_status_checks":{"contexts":%s,"strict":%s},"required_pull_request_reviews":{"required_approving_review_count":%s},"enforce_admins":{"enabled":%s}}' "$1" "$2" "$3" "$4"
}

printf "\n\033[1mThe shape petedio-iac is declared to have\033[0m\n"
case_ "contexts, reviews, strict and admins all match" \
  "$(prot '["validate","gate"]' true 1 false)" 'ctx=gate,validate reviews=1 strict=yes admins=no' ''

case_ "context order does not matter" \
  "$(prot '["gate","validate"]' true 1 false)" 'ctx=validate,gate reviews=1' ''

printf "\n\033[1mThe PET-418 event: a PUT dropped the contexts\033[0m\n"
case_ "one context silently removed" \
  "$(prot '["validate"]' true 1 false)" 'ctx=gate,validate reviews=1' 'contexts are \[validate\], declared \[gate,validate\]'

case_ "every context removed, object otherwise intact" \
  "$(prot '[]' true 1 false)" 'ctx=gate,validate' 'contexts are \[\], declared \[gate,validate\]'

case_ "a context added that nobody declared" \
  "$(prot '["validate","gate","apply"]' true 1 false)" 'ctx=gate,validate' 'contexts are \[apply,gate,validate\]'

printf "\n\033[1mThe fields a full-replacement PUT drops one at a time\033[0m\n"
case_ "required review count fell to zero" \
  "$(prot '["validate","gate"]' true 0 false)" 'ctx=gate,validate reviews=1' 'required reviews 0, declared 1'

case_ "strict (branch must be up to date) turned off" \
  "$(prot '["validate","gate"]' false 1 false)" 'strict=yes' 'strict \(up-to-date\) no, declared yes'

case_ "two fields lost in one event, both reported" \
  "$(prot '["validate"]' false 1 false)" 'ctx=gate,validate strict=yes' 'contexts are.*;.*strict'

printf "\n\033[1mThe deadlock nothing in the org can reproduce (PET-399)\033[0m\n"
case_ "enforce_admins on with one required review" \
  "$(prot '["validate"]' true 1 true)" '' 'DEADLOCK: enforce_admins=true with 1 required review'

case_ "enforce_admins on with no required review is fine — petedio-water-fast" \
  "$(prot '["test"]' true 0 true)" 'ctx=test reviews=0 admins=yes' ''

case_ "one required review with enforce_admins off is fine — petedio-iac" \
  "$(prot '["validate","gate"]' true 1 false)" 'admins=no' ''

case_ "the deadlock fires even when the declared shape matches" \
  "$(prot '["test"]' true 2 true)" 'ctx=test reviews=2 admins=yes' 'DEADLOCK'

printf "\n\033[1mA table row that asks for something the checker does not know\033[0m\n"
case_ "unknown key is reported, not ignored" \
  "$(prot '["validate"]' true 1 false)" 'signatures=yes' "unknown key 'signatures'"

printf "\n\033[1m%d passed, %d failed\033[0m\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
