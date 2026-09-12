#!/usr/bin/env bash
# test-claude-loop-tick.sh — drive scripts/claude-loop-tick.sh through every path it has,
# against a throwaway git remote and stubbed sudo / broker / claude / gh (PET-399).
#
#   ./scripts/test-claude-loop-tick.sh
#
# WHY THIS EXISTS. The tick opens pull requests with a credential, on a host nobody watches
# at 03:00, and the paths that matter most are the ones that must NOT open a pull request.
# Those are unreachable by inspection and expensive to reach by hand: you would need a
# labelled work item, a live App and a real session per case. Everything here runs in a
# temp directory in a couple of seconds, needs no credential and touches no network.
#
# It found two real defects while it was being written, both of which passed the first tick
# and failed the second: `git clean -ffdx` deleted the tick's own checkout marker, and
# `git add -A` committed it into the pull request. That is the class of bug this catches.
#
# Same posture as scripts/test-palworld-unit-render.py — a static check you run by hand, not
# a CI job. Nothing in .github/workflows watches it.
#
# ⚠ IT STUBS `sudo` BY PUTTING ONE FIRST ON PATH. That is safe here — the stub just drops
# `-n` and execs — but it means this script must never be run with anything that matters on
# PATH ahead of it, and it is not a test of the real sudoers grant. The grant is verified by
# the play, which mints a token as the session user.
set -uo pipefail
TICK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/claude-loop-tick.sh"
[ -x "$TICK" ] || { echo "cannot find an executable claude-loop-tick.sh next to this script" >&2; exit 1; }
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }
say() { printf '\n\033[1m%s\033[0m\n' "$1"; }

BIN="$ROOT/bin"; mkdir -p "$BIN"
cat > "$BIN/sudo" <<'S'
#!/usr/bin/env bash
[ "${1:-}" = "-n" ] && shift
exec "$@"
S
cat > "$BIN/gh" <<'S'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_LOG"
case "${1:-} ${2:-}" in
  "pr create") echo "https://github.com/PeteDio-Labs/petedio-iac/pull/999" ;;
  "pr comment") [ "${GH_COMMENT_FAILS:-0}" = 1 ] && { echo "comment refused" >&2; exit 1; } ;;
esac
exit 0
S
chmod +x "$BIN/sudo" "$BIN/gh"
export PATH="$BIN:$PATH"

setup() {  # $1 = broker next-item JSON, $2 = STUB_MODE
  H="$ROOT/h$RANDOM$RANDOM"; mkdir -p "$H"
  ORIGIN="$H/origin.git"; CO="$H/iac"
  git init -q --bare "$ORIGIN"
  git init -q "$H/seed"
  (cd "$H/seed" && git -c user.email=a@b -c user.name=a commit -q --allow-empty -m init \
    && git branch -M main && git remote add origin "$ORIGIN" \
    && git -c user.email=a@b -c user.name=a push -q origin main) >/dev/null 2>&1
  git clone -q "$ORIGIN" "$CO" >/dev/null 2>&1
  touch "$CO/.git/claude-loop-checkout"
  printf 'item {{ITEM_KEY}} / {{ITEM_TITLE}} / diff->{{SPEC_DIFF_PATH}} / {{BRANCH}} / {{REPO}}\n{{ITEM_BODY}}\n' > "$H/prompt.md"

  NEXT_JSON="$1"
  printf '%s' "$NEXT_JSON" > "$H/next.json"
  cat > "$H/broker" <<'S'
#!/usr/bin/env bash
case "$1" in
  next-item)  cat "$(dirname "$0")/next.json" ;;
  mint-token) echo "ghs_faketoken1234567890abcdef" ;;
esac
S
  cat > "$H/claude" <<'S'
#!/usr/bin/env bash
PROMPT="$(cat)"
case "${STUB_MODE:-good}" in
  good)
    echo hello > newfile.txt
    P="$(printf '%s' "$PROMPT" | grep -o 'diff->[^ ]*' | head -1 | cut -c7-)"
    [ -n "$P" ] || { echo "stub: no spec-diff path in the rendered prompt" >&2; exit 9; }
    mkdir -p "$(dirname "$P")"
    printf '| asked | shipped | status |\n|---|---|---|\n| A | done | done |\n' > "$P"
    ;;
  nospecdiff) echo hello > newfile.txt ;;
  nochange)   : ;;
  boom)       exit 3 ;;
esac
exit 0
S
  chmod +x "$H/broker" "$H/claude"
  export CLAUDE_LOOP_HOME="$H" CLAUDE_LOOP_CHECKOUT="$CO" CLAUDE_LOOP_BROKER="$H/broker"
  export CLAUDE_BIN="$H/claude" CLAUDE_LOOP_REPO="PeteDio-Labs/petedio-iac"
  export CLAUDE_LOOP_MAX_ATTEMPTS=2 CLAUDE_LOOP_TIMEOUT_SEC=30 CLAUDE_LOOP_MAX_AGE_SEC=3900
  export GH_LOG="$H/gh.log"; : > "$GH_LOG"
  export GH_COMMENT_FAILS=0
  export STUB_MODE="${2:-good}"
}

hb() { python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2]))" \
  "$CLAUDE_LOOP_HOME/state/last-tick.json" "$1" 2>/dev/null; }

ONE='{"label":"agent-ready","examined":41,"labelled":2,"eligible":1,"items":[{"key":"PET-500","id":"u1","name":"Give the thing a second copy","description":"Do A. Do B."}]}'
NONE='{"label":"agent-ready","examined":41,"labelled":0,"eligible":0,"items":[]}'

say "1. an empty queue parks as no-work and still reports what it examined"
setup "$NONE" good
"$TICK" >"$CLAUDE_LOOP_HOME/out" 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok "exits 0" || no "exits 0" "rc=$RC"
[ "$(hb outcome)" = "no-work" ] && ok "outcome=no-work" || no "outcome=no-work" "got $(hb outcome)"
[ "$(hb examined)" = "41" ] && ok "heartbeat carries examined=41" || no "examined=41" "got $(hb examined)"
[ "$(hb max_age_sec)" = "3900" ] && ok "heartbeat carries max_age_sec" || no "max_age_sec" "got $(hb max_age_sec)"
grep -q "0 eligible of 41 examined" "$CLAUDE_LOOP_HOME/out" && ok "log separates 0-of-41 from 0-of-0" || no "log wording" "$(tail -2 "$CLAUDE_LOOP_HOME/out")"

say "2. the PAUSED sentinel parks before anything else"
setup "$ONE" good
touch "$CLAUDE_LOOP_HOME/PAUSED"
"$TICK" >/dev/null 2>&1
[ "$(hb outcome)" = "paused" ] && ok "outcome=paused" || no "outcome=paused" "got $(hb outcome)"
[ ! -s "$GH_LOG" ] && ok "gh was never called" || no "gh untouched" "$(cat "$GH_LOG")"

say "3. a broker that cannot list work items is a FAILURE, not an idle queue"
setup "$NONE" good
cat > "$CLAUDE_LOOP_HOME/broker" <<'S'
#!/usr/bin/env bash
echo "no label named 'agent-ready' in this project" >&2; exit 1
S
chmod +x "$CLAUDE_LOOP_HOME/broker"
"$TICK" >/dev/null 2>&1; RC=$?
[ "$RC" -ne 0 ] && ok "exits non-zero" || no "exits non-zero" "rc=$RC"
[ "$(hb outcome)" = "failed" ] && ok "outcome=failed, not no-work" || no "outcome=failed" "got $(hb outcome)"
hb detail | grep -q "no label named" && ok "detail carries the broker's reason" || no "detail" "$(hb detail)"

say "4. the happy path opens a DRAFT PR and posts the spec diff"
setup "$ONE" good
"$TICK" >"$CLAUDE_LOOP_HOME/out" 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok "exits 0" || no "exits 0" "rc=$RC · $(hb detail)"
[ "$(hb outcome)" = "worked" ] && ok "outcome=worked" || no "outcome=worked" "got $(hb outcome) / $(hb detail)"
[ "$(hb item)" = "PET-500" ] && ok "heartbeat names the item" || no "item" "got $(hb item)"
hb pr | grep -q "pull/999" && ok "heartbeat carries the PR url" || no "pr url" "got $(hb pr)"
grep -q -- "--draft" "$GH_LOG" && ok "the PR is created --draft" || no "--draft" "$(cat "$GH_LOG")"
grep -q "pr comment" "$GH_LOG" && ok "the spec diff posts as a comment" || no "pr comment" "$(cat "$GH_LOG")"
! grep -qE "pr (merge|ready)" "$GH_LOG" && ok "nothing merges or marks ready" || no "no merge/ready" "$(cat "$GH_LOG")"
git -C "$CLAUDE_LOOP_CHECKOUT" rev-parse --abbrev-ref HEAD | grep -q "^pet-500-give-the-thing" \
  && ok "branch is pet-500-<slug>" || no "branch name" "$(git -C "$CLAUDE_LOOP_CHECKOUT" rev-parse --abbrev-ref HEAD)"
git -C "$CLAUDE_LOOP_CHECKOUT" ls-remote --heads origin 2>/dev/null | grep -q pet-500 \
  && ok "the branch reached origin" || no "push" ""
git -C "$CLAUDE_LOOP_CHECKOUT" show --stat --name-only HEAD | grep -q "claude-loop-checkout" \
  && no "the marker leaked into the commit" "" || ok "the marker stays out of the commit"

say "5. a session that writes NO spec diff opens no PR"
setup "$ONE" nospecdiff
"$TICK" >/dev/null 2>&1
[ "$(hb outcome)" = "failed" ] && ok "outcome=failed" || no "outcome=failed" "got $(hb outcome)"
hb detail | grep -q "spec-diff" && ok "detail names the missing spec diff" || no "detail" "$(hb detail)"
[ ! -s "$GH_LOG" ] && ok "no PR was opened" || no "no PR" "$(cat "$GH_LOG")"

say "6. a session that changes nothing opens no PR"
setup "$ONE" nochange
"$TICK" >/dev/null 2>&1
[ "$(hb outcome)" = "failed" ] && ok "outcome=failed" || no "outcome=failed" "got $(hb outcome)"
hb detail | grep -q "no diff" && ok "detail says there was no diff" || no "detail" "$(hb detail)"
[ ! -s "$GH_LOG" ] && ok "no PR was opened" || no "no PR" "$(cat "$GH_LOG")"

say "7. an item that keeps failing is given up on after max_attempts"
setup "$ONE" boom
for _ in 1 2 3; do "$TICK" >/dev/null 2>&1; done
A="$(python3 -c "import json;print(json.load(open('$CLAUDE_LOOP_HOME/state/items/PET-500.json'))['attempts'])" 2>/dev/null)"
[ "$A" = "2" ] && ok "attempts stops at the cap of 2" || no "attempts cap" "got $A"
[ "$(hb outcome)" = "no-work" ] && ok "the third tick parks as no-work" || no "third tick parks" "got $(hb outcome)"

say "8. an item whose branch already exists on origin does not get a second PR"
setup "$ONE" good
"$TICK" >/dev/null 2>&1
[ "$(hb outcome)" = "worked" ] && ok "first tick worked" || no "first tick" "$(hb detail)"
rm -f "$CLAUDE_LOOP_HOME/state/items/PET-500.json"   # a lost claim record
: > "$GH_LOG"
"$TICK" >/dev/null 2>&1
[ "$(hb outcome)" = "skipped" ] && ok "second tick outcome=skipped" || no "outcome=skipped" "got $(hb outcome) / $(hb detail)"
[ ! -s "$GH_LOG" ] && ok "no second PR" || no "no second PR" "$(cat "$GH_LOG")"

say "9. the tick refuses to reset a directory that is not its own"
setup "$ONE" good
rm -f "$CLAUDE_LOOP_CHECKOUT/.git/claude-loop-checkout"
"$TICK" >/dev/null 2>&1
[ "$(hb outcome)" = "failed" ] && ok "outcome=failed" || no "outcome=failed" "got $(hb outcome)"
hb detail | grep -q "claude-loop-checkout" && ok "detail names the missing marker" || no "detail" "$(hb detail)"

say "10. a PR that opens but whose spec diff fails to post says so loudly"
setup "$ONE" good
export GH_COMMENT_FAILS=1
"$TICK" >/dev/null 2>&1
[ "$(hb outcome)" = "worked" ] && ok "the PR still counts as worked" || no "worked" "got $(hb outcome) / $(hb detail)"
hb detail | grep -q "spec diff failed to post" && ok "detail flags the missing comment" || no "detail" "$(hb detail)"

say "11. a second tick while one holds the lock parks as busy"
setup "$ONE" good
( exec 9>"$CLAUDE_LOOP_HOME/tick.lock"; flock 9; sleep 3 ) &
sleep 0.4
"$TICK" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok "exits 0" || no "exits 0" "rc=$RC"
[ "$(hb outcome)" = "busy" ] && ok "outcome=busy" || no "outcome=busy" "got $(hb outcome)"
wait

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
