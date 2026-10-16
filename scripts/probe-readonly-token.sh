#!/usr/bin/env bash
# probe-readonly-token.sh — prove that `claude-ops-github-broker mint-token --read-only`
# yields a token GitHub lets read and refuses to write (PET-617).
#
# WHY THIS EXISTS. pm-agent on claude-247 gets its GitHub access from this broker mode, and
# the whole design rests on GitHub honoring the `permissions` object in the access-token
# request. Nobody has proven that yet: the sessions' auto mode refuses to mint tokens to test
# it, so Pedro runs this script himself. It prints status codes and PASS or FAIL lines, never
# a token.
#
# WHAT EACH STEP PROVES.
#
#   1. The control. A normal (write) token tries to create a ref at the all-zero SHA. GitHub
#      checks permission before it validates the SHA, so a token that may write gets 422 and
#      one that may not gets 403. Nothing is created either way. Without a 422 here, a 403 in
#      step 3 would prove nothing.
#   2. The read-only token reads the repository, its pull requests and a file: each is 200.
#   3. The read-only token makes the same ref request as step 1: it must get 403.
#   4. The token is narrowed to one repository: a second, PRIVATE repository answers 404.
#      A public one would answer 200 to any token, so it would prove nothing.
#
# Both tokens are revoked at the end, so neither outlives the run.
#
# RUN IT AFTER the broker change in this PR is on claude-247 (scripts/deploy-claude-247.sh),
# as claude-ops, the only user that can run the broker:
#
#   ./scripts/probe-readonly-token.sh                    # pete-bot, then petedio-search for step 4
#   ./scripts/probe-readonly-token.sh <repo> <other-private-repo>
#
# Exit status: 0 when every step passes, 1 when any fails, 2 when the control is
# inconclusive or the broker has no --read-only mode.
set -uo pipefail

ORG=PeteDio-Labs
REPO="${1:-pete-bot}"
OTHER="${2:-petedio-search}"
BROKER="${BROKER:-$HOME/.local/bin/claude-ops-github-broker}"
API=https://api.github.com
ZERO_SHA=0000000000000000000000000000000000000000
PASS=0; FAIL=0

die() { printf 'probe-readonly-token: %s\n' "$*" >&2; exit 2; }
ok() { printf 'PASS  %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }

[ -x "$BROKER" ] || die "$BROKER is missing or not executable. Run this on claude-247 as claude-ops."
# An unknown option makes the broker print its usage and exit 1 before it mints anything.
usage="$("$BROKER" mint-token --read-only --probe-usage 2>&1 || true)"
case "$usage" in
  *--read-only*) ;;
  *) die "the broker has no --read-only mode yet. Deploy this PR's broker first (scripts/deploy-claude-247.sh)." ;;
esac

# status TOKEN METHOD PATH [BODY] — prints the HTTP status only. The token travels on stdin,
# never in argv, so `ps` never shows it.
status() {
  local token="$1" method="$2" path="$3" body="${4:-}"
  local args=(-sS -o /dev/null -w '%{http_code}' --max-time 20 -X "$method" -H @-
    -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28')
  [ -n "$body" ] && args+=(--data-binary "$body")
  printf 'Authorization: Bearer %s\n' "$token" | curl "${args[@]}" "$API$path"
}

expect() {
  local want="$1" got="$2" what="$3"
  if [ "$got" = "$want" ]; then ok "$what: $got"; else bad "$what: got $got, want $want"; fi
}

WRITE_TOKEN='' RO_TOKEN=''
revoke() {
  local t
  for t in "$WRITE_TOKEN" "$RO_TOKEN"; do
    [ -n "$t" ] && status "$t" DELETE /installation/token >/dev/null
  done
}
trap revoke EXIT

REF_BODY="$(printf '{"ref":"refs/heads/pet-617-probe","sha":"%s"}' "$ZERO_SHA")"

echo "== 1. The control: a write token on $ORG/$REPO"
WRITE_TOKEN="$("$BROKER" mint-token "$REPO")" || die "the broker could not mint a write token for $REPO."
control="$(status "$WRITE_TOKEN" POST "/repos/$ORG/$REPO/git/refs" "$REF_BODY")"
if [ "$control" = 422 ]; then
  ok "a write token's zero-SHA ref request gets 422, so a 403 below means 'may not write'"
else
  die "the control got $control, not 422, so step 3 could not tell read-only from broken. Nothing is proven."
fi

echo "== 2. The read-only token reads $ORG/$REPO"
RO_TOKEN="$("$BROKER" mint-token --read-only "$REPO")" || { bad "the broker refused to mint a read-only token (its error is above)"; RO_TOKEN=''; }
if [ -n "$RO_TOKEN" ]; then
  ok "the broker minted it, and GitHub granted only read permissions"
  expect 200 "$(status "$RO_TOKEN" GET "/repos/$ORG/$REPO")" "read the repository"
  expect 200 "$(status "$RO_TOKEN" GET "/repos/$ORG/$REPO/pulls?state=all&per_page=1")" "list pull requests"
  expect 200 "$(status "$RO_TOKEN" GET "/repos/$ORG/$REPO/readme")" "read the README"

  echo "== 3. The read-only token may not write"
  expect 403 "$(status "$RO_TOKEN" POST "/repos/$ORG/$REPO/git/refs" "$REF_BODY")" "the same ref request as the control"

  echo "== 4. The read-only token reaches no other repository"
  expect 404 "$(status "$RO_TOKEN" GET "/repos/$ORG/$OTHER")" "read $ORG/$OTHER"
fi

echo "== $PASS passed, $FAIL failed. Both tokens are revoked on exit."
[ "$FAIL" -eq 0 ]
