#!/usr/bin/env bash
# test-plane-sync — run plane-sync.sh against a Plane that answers on demand.
#
# WHY: plane-sync.sh resolves PET-<n> with one GET to the workspace-level
# by-identifier route (PET-503), and the paths that matter cannot be reached on
# demand against the live board: an item already in the target state, an item that
# moves, a 404, a Plane that drops off the network, and an identifier that resolves
# to another project. So `curl` is a shim here. It answers each case from the
# environment and records every call, and the assertions count the calls as well
# as reading the messages.
#
#   ./scripts/test-plane-sync.sh
#
# Contacts nothing. No token, no network. Needs bash and python3, as the target does.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET="$HERE/plane-sync.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

# ---- the shim -------------------------------------------------------------------
# The states route always answers. The by-identifier route answers by ITEM_MODE:
# `found` serves item-<n> in project ITEM_PROJECT with state ITEM_STATE, `missing`
# answers 404 for an item, `noroute` answers 404 with the body the lab's Plane gives
# a route it does not have, `down` fails the way curl fails on a refused connection
# (exit 7, http_code 000), `foreign` serves the item in another project, `garbage`
# answers 200 with a body that is not JSON, and `error` answers 500.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/curl" <<'SHIM'
#!/usr/bin/env bash
method=GET; url=""; out=""; data=""; fmt=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift ;;
    -o) out="$2"; shift ;;
    -d) data="$2"; shift ;;
    -w) fmt="$2"; shift ;;
    -H|--max-time) shift ;;
    http*) url="$1" ;;
  esac
  shift
done
printf '%s %s %s\n' "$method" "$url" "$data" >>"$SHIM_LOG"
emit() {  # code, body: write the body where -o points, print the code if -w asked
  if [ -n "$out" ]; then printf '%s' "$2" >"$out"; else printf '%s' "$2"; fi
  [ -z "$fmt" ] || printf '%s' "$1"
}
case "$method $url" in
  PATCH*) emit 200 '{}' ;;
  "GET "*/projects/*/states/*)
    emit 200 '{"results": [{"id": "st-todo", "name": "Todo"}, {"id": "st-prog", "name": "In Progress"}, {"id": "st-rev", "name": "In Review"}, {"id": "st-done", "name": "Done"}]}' ;;
  "GET "*/workspaces/*/work-items/PET-*/)
    n="${url%/}"; n="${n##*/PET-}"
    case "$ITEM_MODE" in
      found)   emit 200 "{\"id\": \"item-$n\", \"sequence_id\": $n, \"project\": \"$ITEM_PROJECT\", \"state\": \"$ITEM_STATE\"}" ;;
      foreign) emit 200 "{\"id\": \"item-$n\", \"sequence_id\": $n, \"project\": \"other-proj\", \"state\": \"st-prog\"}" ;;
      missing) emit 404 '{"error": "Work item not found."}' ;;
      noroute) emit 404 '{"error": "Page not found."}' ;;
      garbage) emit 200 '<html>not json</html>' ;;
      error)   emit 500 '{"error": "Internal Server Error"}' ;;
      down)    [ -z "$fmt" ] || printf '000'
               echo "curl: (7) Failed to connect to plane.test port 80: Connection refused" >&2
               exit 7 ;;
    esac ;;
  *) emit 404 "{\"error\": \"unexpected url $url\"}" ;;
esac
exit 0
SHIM
chmod +x "$TMP/bin/curl"

# name, head ref, transition, item mode, item state, want (regex over the output
# joined by |), lookups wanted, PATCHes wanted, [want in the call log (regex)]
case_() {
  local name="$1" ref="$2" transition="$3" mode="$4" state="$5" want="$6" lookups="$7" patches="$8" wantlog="${9:-}"
  local got rc joined nlook npatch logok=1
  : >"$TMP/log"
  got=$(PATH="$TMP/bin:$PATH" SHIM_LOG="$TMP/log" \
        ITEM_MODE="$mode" ITEM_STATE="$state" ITEM_PROJECT=proj \
        PLANE_BASE_URL=http://plane.test PLANE_WORKSPACE=ws PLANE_PROJECT_ID=proj \
        PLANE_API_KEY=not-a-key PLANE_TRANSITION="$transition" HEAD_REF="$ref" \
        bash "$TARGET" 2>&1)
  rc=$?
  joined=$(printf '%s' "$got" | tr '\n' '|')
  nlook=$(grep -c '^GET http://plane\.test/api/v1/workspaces/ws/work-items/PET-[0-9]*/ $' "$TMP/log")
  npatch=$(grep -c '^PATCH ' "$TMP/log")
  [ -z "$wantlog" ] || grep -qE "$wantlog" "$TMP/log" || logok=0
  if [ "$rc" -eq 0 ] && printf '%s' "$joined" | grep -qE "$want" \
     && [ "$nlook" = "$lookups" ] && [ "$npatch" = "$patches" ] && [ "$logok" = 1 ]; then
    PASS=$((PASS+1)); printf "  \033[32m✓\033[0m %s\n      %s\n" "$name" "$(printf '%s' "$got" | tail -n 1)"
  else
    FAIL=$((FAIL+1))
    printf "  \033[31m✗\033[0m %s\n      rc=%s  lookups=%s (want %s)  PATCHes=%s (want %s)  log ok=%s\n      got:  %s\n      want: %s\n" \
      "$name" "$rc" "$nlook" "$lookups" "$npatch" "$patches" "$logok" "$joined" "$want"
  fi
}

printf "\n\033[1mThe item resolves in one GET\033[0m\n"
case_ "PET-386 already Done: found, and no PATCH" pet-386-kuma-backup-to-ollama-host 'done' found st-done \
  'PET-386 resolved by identifier in one GET.*PET-386 already Done — no change' 1 0

case_ "PET-500 In Review: found, then one PATCH to Done" pet-500-fixture 'done' found st-rev \
  'PET-500 resolved by identifier in one GET.*PET-500 .+ Done ✓' 1 1 \
  '^PATCH http://plane\.test/api/v1/workspaces/ws/projects/proj/work-items/item-500/ \{"state": "st-done"\}$'

printf "\n\033[1mA lookup that fails leaves the item as-is\033[0m\n"
# The two 404 bodies get the same warning: the script does not tell them apart.
case_ "PET-999 answers 404 for a missing item" pet-999-fixture 'done' missing - \
  'PET-999 answered 404: the branch names a work item that does not exist, or this Plane has no by-identifier route \(/api/v1/workspaces/ws/work-items/PET-999/\)' 1 0

case_ "PET-999 answers 404 with the lab's unknown-route body" pet-999-fixture 'done' noroute - \
  'PET-999 answered 404: the branch names a work item that does not exist, or this Plane has no by-identifier route \(/api/v1/workspaces/ws/work-items/PET-999/\)' 1 0

case_ "a 200 body that is not a work item" pet-386-fixture 'done' garbage - \
  'could not parse the work item returned for PET-386 — left as-is' 1 0

case_ "an HTTP 500" pet-386-fixture 'done' error - \
  'resolving PET-386 returned HTTP 500 — left as-is' 1 0

case_ "Plane unreachable at the lookup" pet-386-fixture 'done' down - \
  'Plane unreachable at http://plane\.test while resolving PET-386' 1 0

case_ "a 200 for another project" pet-386-fixture 'done' foreign - \
  'PET-386 resolved to project other-proj, not proj — left as-is' 1 0

printf "\n\033[1mUnchanged behaviour\033[0m\n"
case_ "a branch without the prefix syncs nothing" docs-typo 'done' found st-done \
  'carries no pet-<n>- prefix' 0 0

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
