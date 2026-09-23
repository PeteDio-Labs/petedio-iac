#!/usr/bin/env bash
# test-plane-sync — walk plane-sync.sh across a board bigger than one page.
#
# WHY: plane-sync.sh read one page of 100 work items and reported PET-386, which
# sat past page one of a 213-item board, as a work item that did not exist
# (PET-502). The lookup pages now, and the paths that matter cannot be reached on
# demand against the live board: a hit on a later page, a hit on the last partial
# page, a miss after every page, a stop at the first match, a cursor that never
# advances, a list that never ends. So `curl` is a shim here. It serves a board
# from a generator and records every call, and the assertions count the calls as
# well as reading the messages.
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
# The board has BOARD_TOTAL items with sequence ids counting down from BOARD_TOP,
# newest first, served in pages of `per_page` under Plane's `per_page:page:is_prev`
# cursor. BOARD_HIT names one item and BOARD_HIT_STATE its state; every other item
# is In Progress. BOARD_MODE bends the board: `garbage` answers with text that is
# not JSON, `stuck` reports more pages but never moves the cursor, and `endless`
# serves a full page with more to come, forever.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/curl" <<'SHIM'
#!/usr/bin/env bash
method=GET; url=""; out=""; data=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift ;;
    -o) out="$2"; shift ;;
    -d) data="$2"; shift ;;
    -H|--max-time|-w) shift ;;
    http*) url="$1" ;;
  esac
  shift
done
printf '%s %s %s\n' "$method" "$url" "$data" >>"$SHIM_LOG"
if [ "$method" = PATCH ]; then
  [ -n "$out" ] && printf '{}' >"$out"
  printf '200'      # what -w '%{http_code}' prints
  exit 0
fi
python3 - "$url" <<'PY'
import json, os, sys, urllib.parse
url = sys.argv[1]
path, _, query = url.partition('?')
q = urllib.parse.parse_qs(query)
mode = os.environ.get('BOARD_MODE', '')
if path.endswith('/states/'):
    print(json.dumps({'results': [
        {'id': 'st-todo', 'name': 'Todo'}, {'id': 'st-prog', 'name': 'In Progress'},
        {'id': 'st-rev', 'name': 'In Review'}, {'id': 'st-done', 'name': 'Done'}]}))
elif path.endswith('/work-items/'):
    if mode == 'garbage':
        print('<html>not json</html>'); sys.exit(0)
    total = int(os.environ['BOARD_TOTAL']); top = int(os.environ['BOARD_TOP'])
    hit = int(os.environ.get('BOARD_HIT', '0')); hit_state = os.environ.get('BOARD_HIT_STATE', 'st-done')
    per = int(q.get('per_page', ['50'])[0])
    page = int(q.get('cursor', [f'{per}:0:0'])[0].split(':')[1])
    if mode == 'endless':
        seqs = range(top - page * per, top - (page + 1) * per, -1)
    else:
        seqs = list(range(top, top - total, -1))[page * per:(page + 1) * per]
    rows = [{'id': f'item-{s}', 'sequence_id': s, 'name': f'PET-{s}',
             'state': hit_state if s == hit else 'st-prog'} for s in seqs]
    more = True if mode in ('stuck', 'endless') else (page + 1) * per < total
    nxt = f'{per}:{page}:0' if mode == 'stuck' else f'{per}:{page + 1}:0'
    print(json.dumps({'results': rows, 'count': len(rows), 'total_count': total,
                      'next_cursor': nxt, 'prev_cursor': f'{per}:{page - 1}:1',
                      'next_page_results': more}))
else:
    print(json.dumps({'error': 'unexpected url ' + url}))
PY
SHIM
chmod +x "$TMP/bin/curl"

board() {  # top, total, hit, hit-state, [mode]
  export BOARD_TOP="$1" BOARD_TOTAL="$2" BOARD_HIT="$3" BOARD_HIT_STATE="$4" BOARD_MODE="${5:-}"
}

# name, head ref, transition, want (regex over the output joined by |),
# list GETs wanted, PATCHes wanted, [want in the call log (regex)]
case_() {
  local name="$1" ref="$2" transition="$3" want="$4" gets="$5" patches="$6" wantlog="${7:-}"
  local got rc joined ngets npatch logok=1
  : >"$TMP/log"
  got=$(PATH="$TMP/bin:$PATH" SHIM_LOG="$TMP/log" \
        PLANE_BASE_URL=http://plane.test PLANE_WORKSPACE=ws PLANE_PROJECT_ID=proj \
        PLANE_API_KEY=not-a-key PLANE_TRANSITION="$transition" HEAD_REF="$ref" \
        bash "$TARGET" 2>&1)
  rc=$?
  joined=$(printf '%s' "$got" | tr '\n' '|')
  ngets=$(grep -c '^GET .*/work-items/?' "$TMP/log")
  npatch=$(grep -c '^PATCH ' "$TMP/log")
  [ -z "$wantlog" ] || grep -qE "$wantlog" "$TMP/log" || logok=0
  if [ "$rc" -eq 0 ] && printf '%s' "$joined" | grep -qE "$want" \
     && [ "$ngets" = "$gets" ] && [ "$npatch" = "$patches" ] && [ "$logok" = 1 ]; then
    PASS=$((PASS+1)); printf "  \033[32m✓\033[0m %s\n      %s\n" "$name" "$(printf '%s' "$got" | tail -n 1)"
  else
    FAIL=$((FAIL+1))
    printf "  \033[31m✗\033[0m %s\n      rc=%s  list GETs=%s (want %s)  PATCHes=%s (want %s)  log ok=%s\n      got:  %s\n      want: %s\n" \
      "$name" "$rc" "$ngets" "$gets" "$npatch" "$patches" "$logok" "$joined" "$want"
  fi
}

# A 213-item board, ids 502 down to 290: pages of 100, 100 and 13.
printf "\n\033[1mThe PET-502 event: the item sits past page one\033[0m\n"
board 502 213 386 st-done
case_ "PET-386 on page two, already Done: found, and no PATCH" pet-386-kuma-backup-to-ollama-host 'done' \
  'found on page 2 \(200 of 213 work items scanned\).*PET-386 already Done — no change' 2 0

printf "\n\033[1mThe walk stops at the first match\033[0m\n"
board 502 213 500 st-rev
case_ "PET-500 on page one, In Review: one GET, then a PATCH to Done" pet-500-fixture 'done' \
  'found on page 1 \(100 of 213 work items scanned\).*PET-500 .+ Done' 1 1 \
  '^PATCH http://plane\.test/api/v1/workspaces/ws/projects/proj/work-items/item-500/ \{"state": "st-done"\}$'

board 502 213 290 st-rev
case_ "PET-290 on the last, partial page" pet-290-fixture 'done' \
  'found on page 3 \(213 of 213 work items scanned\).*PET-290 .+ Done' 3 1

board 42 42 7 st-done
case_ "a board of one page still resolves on that page" pet-7-fixture 'done' \
  'found on page 1 \(42 of 42 work items scanned\).*PET-7 already Done' 1 0

printf "\n\033[1mA miss says what was scanned\033[0m\n"
board 502 213 0 st-done
case_ "PET-999 is not on the board: every page read, then the count" pet-999-fixture 'done' \
  'PET-999 not found in project proj after scanning 213 of 213 work items over 3 page' 3 0

printf "\n\033[1mA list that misbehaves leaves the item as-is\033[0m\n"
board 502 213 0 st-done garbage
case_ "a body that is not the list" pet-386-fixture 'done' \
  'could not parse the work-item list \(page 1\)' 1 0

board 502 213 0 st-done stuck
case_ "a cursor that never advances" pet-386-fixture 'done' \
  'not found in project proj after scanning 100 of 213 work items over 1 page' 1 0

board 502 999999 0 st-done endless
case_ "a list that never ends stops at the page bound" pet-999-fixture 'done' \
  'gave up after 50 pages \(5000 of 999999 work items\)' 50 0

printf "\n\033[1mUnchanged behaviour\033[0m\n"
board 502 213 386 st-done
case_ "a branch without the prefix syncs nothing" docs-typo 'done' \
  'carries no pet-<n>- prefix' 0 0

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
