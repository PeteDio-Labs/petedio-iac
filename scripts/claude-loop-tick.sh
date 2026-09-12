#!/usr/bin/env bash
# claude-loop-tick.sh — one tick of the ticket-driven work loop on claude-247 (PET-399).
#
# A systemd timer fires this. Each tick does AT MOST ONE work item and exits: take one
# Plane item carrying the `agent-ready` label, run `claude -p` against it, and open a
# DRAFT pull request with a table diffing what the item asked for against what shipped.
# No draining, no parallelism, no merging — ever.
#
# This revives the shape of the agent fleet retired in PET-265 and destroyed in PET-307.
# Two things killed that fleet, and both are answered here rather than in a comment:
#
# PRIVILEGE MODEL (PET-408). This script runs as ROOT and drops to the loop user for
# the two things that must not be root: the `claude -p` session, and every command that
# touches the loop's working tree. The token never exists on the unprivileged side.
#
# It is written this way because the previous shape did not work. The tick ran as `claude`
# and reached its credentials through a sudoers grant — but sudo binds to the UID, not to
# this process, so the `claude -p` session it had just started held the identical grant.
# Since that session's instructions come from a Plane work item, anyone who could write one
# could mint the token directly and skip every guard below. There is now NO sudoers entry
# and NO sudo on this host at all, which restores the role's original rule that the session
# user gets none.
#
#   · IT MERGED ITS OWN WORK. This tick holds a token with contents:write and
#     pull_requests:write, which are the permissions that merge. Nothing here calls merge,
#     but that is not the control — the one required approving review on `main` is, which
#     the bot identity is expected to be unable to supply for its own pull request. That
#     expectation is still DESIGNED rather than VERIFIED; docs/runbooks/claude-loop.md says
#     how to prove it, and why `enforce_admins` must stay false. Read it before you relax
#     anything on `main`.
#   · IT SHIPPED A THIRD OF A SPEC BEHIND A GREEN CHECK. So a tick that cannot produce the
#     spec-diff opens NO pull request (step 8), and a tick that produced no code diff opens
#     none either. A confident summary next to two green checks is exactly the artefact
#     that cost the fleet its credibility.
#
# GUARD ORDER IS THE ONE FROM scripts/engine/engine-loop.sh (445a985^), which had it right:
#   1. PAUSED sentinel   — the kill switch a human can set without a play run.
#   2. flock -n          — one tick at a time, whatever the timer thinks.
#   3. eligible item     — none is an outcome, not an error.
#
# EVERY PATH WRITES THE HEARTBEAT, including the ones that fail. `OUTCOME` starts as
# `failed`, so an unexpected exit records a failure rather than silence: the difference
# between "ran and found nothing" and "did not run" is the whole point of the state file,
# and scripts/lab-verify.sh reads it to tell those apart.
#
# Env (the unit sets all of it — roles/claude-code/templates/claude-loop.service.j2):
#   CLAUDE_LOOP_HOME          state, sentinel, lock, prompt      (~/loop)
#   CLAUDE_LOOP_CHECKOUT      the loop's OWN clone of this repo  (~/loop/iac)
#   CLAUDE_LOOP_BROKER        /usr/local/sbin/claude-loop-broker
#   CLAUDE_LOOP_REPO          owner/repo
#   CLAUDE_LOOP_MAX_ATTEMPTS  give up on an item after this many failed ticks
#   CLAUDE_LOOP_TIMEOUT_SEC   hard ceiling on one `claude -p`
#   CLAUDE_LOOP_MAX_AGE_SEC   written into the heartbeat for lab-verify to compare against
#   CLAUDE_BIN                absolute path to claude (PATH is not to be trusted here)
#
# Run it by hand before you ever enable the timer:
#   ssh claude@192.168.50.247 '~/loop/claude-loop-tick.sh'
#
# `set -e` is on, and it is what makes the EXIT trap honest: an unchecked failure anywhere
# below lands in the trap with OUTCOME still `failed`, instead of running on to the next
# step and eventually reporting a tick that half-happened as a clean one.
set -euo pipefail

LOOP_HOME="${CLAUDE_LOOP_HOME:-$HOME/loop}"
CHECKOUT="${CLAUDE_LOOP_CHECKOUT:-$LOOP_HOME/iac}"
BROKER="${CLAUDE_LOOP_BROKER:-/usr/local/sbin/claude-loop-broker}"
REPO="${CLAUDE_LOOP_REPO:-PeteDio-Labs/petedio-iac}"
MAX_ATTEMPTS="${CLAUDE_LOOP_MAX_ATTEMPTS:-3}"
TIMEOUT_SEC="${CLAUDE_LOOP_TIMEOUT_SEC:-3600}"
MAX_AGE_SEC="${CLAUDE_LOOP_MAX_AGE_SEC:-3900}"
CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.npm-global/bin/claude}"

STATE_DIR="$LOOP_HOME/state"
ITEMS_DIR="$STATE_DIR/items"
PAUSE_FILE="$LOOP_HOME/PAUSED"
LOCK_FILE="$LOOP_HOME/tick.lock"
PROMPT_FILE="$LOOP_HOME/prompt.md"
# The marker the role writes. `git clean -ffdx` below is safe ONLY in a directory that
# belongs to the loop, and this file is how the tick knows it is in one — see step 6.
#
# ⚠ IT LIVES INSIDE .git/ FOR TWO REASONS, both found by running this against a stub. A
# marker in the working tree is untracked, so `git clean -ffdx` deletes it and the SECOND
# tick refuses to run; and `git add -A` stages it, so it lands in the pull request. Nothing
# under .git/ is reachable by either.
MARKER=".git/claude-loop-checkout"

LOOP_USER="${CLAUDE_LOOP_USER:-claude}"

log() { printf '\033[1;34m[claude-loop] %s\033[0m\n' "$*" >&2; }

# Run something as the unprivileged loop user. Everything that reads or writes the working
# tree goes through this, so the tree stays owned by one user and a root-owned object never
# lands in it to break the next session.
#
# When NOT root this is a pass-through, which is deliberate and covers two real cases: an
# operator debugging a tick by hand, and scripts/test-claude-loop-tick.sh. Neither can read
# the 0400 credentials, so both fail at the broker with a clear error rather than silently
# doing something different.
#
# ⚠ runuser, NOT sudo. There is no sudo on this host any more and that is the point
# (PET-408). runuser is setuid-root and drops privilege; it cannot raise it.
as_loop_user() {
  if [ "$(id -u)" -eq 0 ]; then runuser -u "$LOOP_USER" -- "$@"; else "$@"; fi
}

# --- the heartbeat ----------------------------------------------------------------------
# Set by the steps below and flushed by the EXIT trap, whatever happens. `failed` is the
# starting value on purpose: a tick that dies on an unhandled error must not leave a state
# file that reads like a clean idle tick.
OUTCOME=failed
DETAIL="the tick exited before it recorded a reason"
ITEM=""
PR=""
EXAMINED=-1
LABELLED=-1
ELIGIBLE=-1

flush_heartbeat() {
  local rc=$?
  mkdir -p "$STATE_DIR"
  HB_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)" HB_OUT="$OUTCOME" HB_DETAIL="$DETAIL" \
  HB_ITEM="$ITEM" HB_PR="$PR" HB_RC="$rc" HB_MAXAGE="$MAX_AGE_SEC" \
  HB_EXAMINED="$EXAMINED" HB_LABELLED="$LABELLED" HB_ELIGIBLE="$ELIGIBLE" \
  HB_PATH="$STATE_DIR/last-tick.json" \
  python3 -c '
import json, os
# The counts say what the tick EXAMINED, not only what it found. "0 eligible of 41
# examined" and "0 eligible because the query returned nothing" must never look alike —
# lab-verify.sh reports them differently and this is where that distinction is recorded.
json.dump({
    "ts": os.environ["HB_TS"],
    "outcome": os.environ["HB_OUT"],
    "detail": os.environ["HB_DETAIL"],
    "item": os.environ["HB_ITEM"] or None,
    "pr": os.environ["HB_PR"] or None,
    "rc": int(os.environ["HB_RC"]),
    "max_age_sec": int(os.environ["HB_MAXAGE"]),
    "examined": int(os.environ["HB_EXAMINED"]),
    "labelled": int(os.environ["HB_LABELLED"]),
    "eligible": int(os.environ["HB_ELIGIBLE"]),
}, open(os.environ["HB_PATH"], "w"), indent=2)
' || log "could not write the heartbeat — lab-verify will report this host as stalled."
  log "$OUTCOME — $DETAIL"
  exit "$rc"
}
trap flush_heartbeat EXIT

park() { OUTCOME="$1"; DETAIL="$2"; exit 0; }
fail() { OUTCOME=failed; DETAIL="$1"; exit 1; }

mkdir -p "$STATE_DIR" "$ITEMS_DIR"

# --- guard 1: the pause sentinel --------------------------------------------------------
# The kill switch that needs no play run and no root: `touch ~/loop/PAUSED`. It parks the
# loop without disabling the timer, so the heartbeat keeps proving the host is alive.
[ -e "$PAUSE_FILE" ] && park paused "PAUSED sentinel present ($PAUSE_FILE)"

# --- guard 2: one tick at a time --------------------------------------------------------
# `Persistent=true` on the timer can fire a catch-up tick straight into a running one, and
# a `claude -p` run can outlast an OnCalendar interval. Non-blocking on purpose: a queued
# second tick would just pile up behind the first.
exec 9>"$LOCK_FILE" || fail "cannot open the lock file $LOCK_FILE"
flock -n 9 || park busy "another tick holds $LOCK_FILE"

# gh is as load-bearing here as git: a tick that discovers it missing at step 9, after
# running a session, has burned the quota to find out.
for t in git flock python3 timeout gh; do
  command -v "$t" >/dev/null || fail "$t is not in PATH"
done

# runuser is required ONLY when this runs as root, which is the only time it is called.
# Demanding it unconditionally breaks a hand-run as the loop user for a reason that has
# nothing to do with the tick: runuser lives in /usr/sbin, which is not on a non-root PATH.
# The unit's own PATH carries /usr/sbin and /sbin, so the root path resolves it.
#
# ⚠ Without runuser, a root tick would run `claude -p` AS ROOT. Claude Code refuses
# bypassPermissions as root, so it would fail — but it would fail late, after the item was
# claimed. Fail here instead, and say why.
if [ "$(id -u)" -eq 0 ]; then
  command -v runuser >/dev/null \
    || fail "runuser is not in PATH and this tick is root — it cannot drop privilege to run the session"
fi
[ -x "$CLAUDE_BIN" ] || fail "claude is not executable at $CLAUDE_BIN"
[ -r "$PROMPT_FILE" ] || fail "the loop prompt is missing at $PROMPT_FILE — re-run the play"

# --- guard 3: is there work? -------------------------------------------------------------
# The broker exits non-zero on every structural surprise, so a failure here is a real
# failure and not an idle queue. Do not soften it into a warning.
QUERY="$("$BROKER" next-item 2>"$STATE_DIR/next-item.err")" \
  || fail "the broker could not list work items: $(tr '\n' ' ' < "$STATE_DIR/next-item.err" | head -c 300)"

EXAMINED="$(printf '%s' "$QUERY" | python3 -c 'import json,sys; print(json.load(sys.stdin)["examined"])' 2>/dev/null)" \
  || fail "the broker returned something that is not the expected JSON"
LABELLED="$(printf '%s' "$QUERY" | python3 -c 'import json,sys; print(json.load(sys.stdin)["labelled"])')"
ELIGIBLE="$(printf '%s' "$QUERY" | python3 -c 'import json,sys; print(json.load(sys.stdin)["eligible"])')"
log "examined ${EXAMINED} work items, ${LABELLED} labelled, ${ELIGIBLE} eligible"

# Pick the first eligible item this loop has not already used up.
#
# ⚠ THE CLAIM RECORD IS BELT AND BRACES, NOT BOOKKEEPING. The broker already filters to
# Todo, and opening a draft PR on a `pet-<n>-` branch fires plane-sync.yml, which moves the
# item to In Progress. But plane-sync is ADVISORY — it exits 0 on every failure path so a
# tracker outage cannot block a merge across nine repos — so an outage would leave the item
# in Todo and the next tick would open a second PR for it. The claim file is what stops
# that, and it is also where the attempt count lives so one broken item cannot burn the
# shared Max quota every half hour forever.
PICK="$(printf '%s' "$QUERY" | ITEMS_DIR="$ITEMS_DIR" MAX_ATTEMPTS="$MAX_ATTEMPTS" python3 -c '
import json, os, sys
items = json.load(sys.stdin)["items"]
d, cap = os.environ["ITEMS_DIR"], int(os.environ["MAX_ATTEMPTS"])
for it in items:
    p = os.path.join(d, it["key"] + ".json")
    if os.path.exists(p):
        try:
            st = json.load(open(p))
        except Exception:
            continue          # unreadable claim: leave it alone, a human should look
        if st.get("outcome") == "worked":
            continue          # already has a PR from this loop
        if int(st.get("attempts", 0)) >= cap:
            continue          # given up on; clearing the file retries it
    json.dump(it, sys.stdout)
    break
')"

if [ -z "$PICK" ]; then
  # An empty queue and a queue of items this loop has given up on are different facts.
  park no-work "0 eligible of ${EXAMINED} examined (${LABELLED} labelled); nothing new to take"
fi

ITEM="$(printf '%s' "$PICK" | python3 -c 'import json,sys; print(json.load(sys.stdin)["key"])')"
TITLE="$(printf '%s' "$PICK" | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])')"
SEQ="${ITEM#PET-}"
# plane-sync.yml matches `^pet-([0-9]+)-` on the branch name to find the work item again,
# so a non-numeric key here would open a PR that never syncs its state back.
[[ "$SEQ" =~ ^[0-9]+$ ]] || fail "work item key '$ITEM' is not PET-<n>"
log "taking $ITEM — $TITLE"

# --- step 5: claim it before doing anything that can fail --------------------------------
# Written FIRST so a tick that dies mid-run still counts as an attempt. Claiming after the
# work would let a crash loop retry the same item forever.
CLAIM="$ITEMS_DIR/$ITEM.json"
ATTEMPTS="$(CLAIM="$CLAIM" python3 -c '
import json, os
try:
    n = int(json.load(open(os.environ["CLAIM"])).get("attempts", 0))
except Exception:
    n = 0
print(n + 1)
')"
record_claim() {
  CLAIM="$CLAIM" C_ITEM="$ITEM" C_ATT="$ATTEMPTS" C_OUT="$1" C_DETAIL="$2" C_PR="${3:-}" \
  C_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  python3 -c '
import json, os
json.dump({
    "item": os.environ["C_ITEM"],
    "attempts": int(os.environ["C_ATT"]),
    "outcome": os.environ["C_OUT"],
    "detail": os.environ["C_DETAIL"],
    "pr": os.environ["C_PR"] or None,
    "ts": os.environ["C_TS"],
}, open(os.environ["CLAIM"], "w"), indent=2)
'
}
record_claim in-progress "attempt ${ATTEMPTS} of ${MAX_ATTEMPTS} started"

# From here on, any failure records the attempt against the item as well as the tick.
fail_item() {
  record_claim failed "$1"
  fail "$ITEM: $1"
}

# --- step 6: a clean branch, in the loop's OWN clone -------------------------------------
#
# ⚠ NOT {{ claude_workspace }}/iac. That clone is what a human drives over SSH and what the
# remote-control servers hand out worktrees from, and this step resets and cleans whatever
# it is pointed at. A tick must never be able to throw away someone's uncommitted work.
#
# `claude -p` does NOT need a pre-trusted directory — the workspace trust dialog is skipped
# in non-interactive mode — so the separate clone costs nothing that the shared one bought.
# Trust it by hand anyway if you want MCP tools resolving in a tick (see the runbook).
[ -d "$CHECKOUT/.git" ] || fail_item "the loop's clone is missing at $CHECKOUT — re-run the play"
[ -f "$CHECKOUT/$MARKER" ] || fail_item "$CHECKOUT carries no $MARKER — refusing to reset a directory that may not be the loop's"

SLUG="$(printf '%s' "$TITLE" | tr '[:upper:]' '[:lower:]' \
  | sed -e 's/[^a-z0-9]\+/-/g' -e 's/^-*//' -e 's/-*$//' | cut -c1-40 | sed -e 's/-*$//')"
[ -n "$SLUG" ] || SLUG=work
BRANCH="pet-${SEQ}-${SLUG}"

as_loop_user git -C "$CHECKOUT" fetch --prune origin 2>&1 | sed 's/^/    /' >&2 \
  || fail_item "git fetch failed"

# An existing remote branch means a previous tick already pushed for this item — the claim
# record was lost or cleared. Opening a second PR for one work item is exactly the mess
# this loop exists to avoid, so stop and let a human look.
if as_loop_user git -C "$CHECKOUT" ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
  record_claim worked "origin already has $BRANCH — a previous tick pushed it"
  park skipped "$ITEM already has the branch $BRANCH on origin; not opening a second PR"
fi

as_loop_user git -C "$CHECKOUT" reset --hard >/dev/null 2>&1 || true
as_loop_user git -C "$CHECKOUT" clean -ffdx >/dev/null 2>&1 || true
as_loop_user git -C "$CHECKOUT" checkout -B "$BRANCH" origin/main >/dev/null 2>&1 \
  || fail_item "could not branch $BRANCH off origin/main"
log "branch $BRANCH off origin/main"

# --- step 7: the session ------------------------------------------------------------------
# One `claude -p` run, boxed by `timeout`. There is no --max-turns in this Claude Code, so
# wall-clock is the only ceiling available and the unit carries a matching one; without it a
# stuck session would hold the lock and every later tick would park as `busy`.
#
# The prompt goes in on STDIN rather than argv: it carries the whole work item, and argv is
# readable by anything on the host through /proc/<pid>/cmdline.
TICK_DIR="$LOOP_HOME/run/$ITEM"
rm -rf "$TICK_DIR"
mkdir -p "$TICK_DIR"
SPEC_DIFF="$TICK_DIR/spec-diff.md"

PICK="$PICK" SPEC_DIFF="$SPEC_DIFF" BRANCH="$BRANCH" REPO="$REPO" \
PROMPT_FILE="$PROMPT_FILE" OUT="$TICK_DIR/prompt.txt" python3 -c '
import json, os
item = json.loads(os.environ["PICK"])
body = open(os.environ["PROMPT_FILE"]).read()
body = (body
        .replace("{{ITEM_KEY}}", item["key"])
        .replace("{{ITEM_TITLE}}", item["name"])
        .replace("{{ITEM_BODY}}", item["description"] or "(the work item has no description)")
        .replace("{{SPEC_DIFF_PATH}}", os.environ["SPEC_DIFF"])
        .replace("{{BRANCH}}", os.environ["BRANCH"])
        .replace("{{REPO}}", os.environ["REPO"]))
open(os.environ["OUT"], "w").write(body)
' || fail_item "could not render the loop prompt"

log "running claude -p (ceiling ${TIMEOUT_SEC}s)"
cd "$CHECKOUT" || fail_item "cannot enter $CHECKOUT"
# `|| SESSION_RC=$?` and not a bare `$?` on the next line: under `set -e` a non-zero timeout
# aborts before anything reads it, and the tick would then report the generic starting
# failure instead of "the session hit the ceiling".
SESSION_RC=0
as_loop_user timeout --signal=TERM --kill-after=60 "$TIMEOUT_SEC" \
  "$CLAUDE_BIN" -p --permission-mode bypassPermissions \
  < "$TICK_DIR/prompt.txt" > "$TICK_DIR/session.log" 2>&1 || SESSION_RC=$?
if [ "$SESSION_RC" -eq 124 ]; then
  fail_item "the session hit the ${TIMEOUT_SEC}s ceiling; see $TICK_DIR/session.log"
elif [ "$SESSION_RC" -ne 0 ]; then
  fail_item "the session exited $SESSION_RC; see $TICK_DIR/session.log"
fi

# --- step 8: refuse to open a PR over work that did not happen ---------------------------
#
# ⚠ THIS IS THE STEP THE RETIRED FLEET DID NOT HAVE. It shipped a third of a spec behind a
# green check, and the retirement note's conclusion was blunt: a passing test suite is not
# evidence of a complete implementation. So two things must BOTH be true before a pull
# request exists, and neither is inferred from the session saying it is done.
as_loop_user git -C "$CHECKOUT" add -A >/dev/null 2>&1 || fail_item "could not stage the session's work"
if as_loop_user git -C "$CHECKOUT" diff --cached --quiet origin/main -- 2>/dev/null; then
  fail_item "the session produced no diff against origin/main — nothing to open a PR for"
fi
[ -s "$SPEC_DIFF" ] \
  || fail_item "the session wrote no spec-diff at $SPEC_DIFF — refusing to open a PR that nobody can check against the work item"

COMMITTED="$(as_loop_user git -C "$CHECKOUT" diff --cached --name-only origin/main | wc -l | tr -d ' ')"
# `core.hooksPath=/dev/null`: a session-planted pre-commit hook runs between the two checks
# above and this commit, and could put back exactly what they just rejected. No token is in
# the environment yet, so this is an integrity guard rather than a credential one.
as_loop_user git -C "$CHECKOUT" -c core.hooksPath=/dev/null \
  -c user.name="claude-loop" -c user.email="claude-loop@pdlab.dev" \
  commit -q -m "${ITEM}: ${TITLE}" -m "Opened by the claude-247 work loop (PET-399). Draft: a human reviews and merges." \
  || fail_item "could not commit the session's work"
log "committed ${COMMITTED} files"

# --- step 9: push and open the DRAFT pull request ----------------------------------------
#
# ⚠ EVERYTHING IN THIS STEP ASSUMES THE SESSION WAS HOSTILE. It ran as this user, in this
# directory, moments ago, with a prompt built from work-item text this loop does not
# control. So `$CHECKOUT/.git` — config, hooks, refs — is attacker-writable by the time we
# get here, and each guard below exists because one specific thing in it is not.
#
# ASSERT THE REMOTE BEFORE MINTING. The token must not exist while the destination is still
# unverified. `ls-remote --get-url` is the right question and `remote get-url` is the wrong
# one: only the former applies `url.<base>.insteadOf`, so a session that rewrote the URL
# that way passes the wrong check while the rewrite is live.
# EXPECT_REMOTE is derived, not configured, in production — the unit passes the same value
# the repo name implies. It is overridable ONLY so scripts/test-claude-loop-tick.sh can
# point a test at a throwaway local remote; that is safe because the env comes from the
# systemd unit and this script's own process, and the session is a CHILD, which cannot
# reach back and change its parent's environment.
EXPECT_REMOTE="${CLAUDE_LOOP_REMOTE:-https://github.com/${REPO}}"
ACTUAL_REMOTE="$(as_loop_user git -C "$CHECKOUT" ls-remote --get-url origin 2>/dev/null || true)"
case "$ACTUAL_REMOTE" in
  "$EXPECT_REMOTE" | "${EXPECT_REMOTE}.git") ;;
  *) fail_item "origin resolves to '${ACTUAL_REMOTE:-nothing}', not ${EXPECT_REMOTE} — refusing to mint a token for it" ;;
esac

# The token is minted here and nowhere earlier, so it exists for the shortest time that
# works. It expires in an hour regardless.
TOKEN="$("$BROKER" mint-token 2>"$STATE_DIR/mint.err")" \
  || fail_item "could not mint a GitHub token: $(tr '\n' ' ' < "$STATE_DIR/mint.err" | head -c 200)"
[ -n "$TOKEN" ] || fail_item "the broker minted an empty token"

# ⚠ NOT `export GH_TOKEN`. An exported token is in the environment of every child this
# script spawns, and git spawns plenty it does not control: a session-planted
# .git/hooks/pre-push, a `core.fsmonitor`, a `filter.*.clean`. Each would read the token
# straight out of /proc/self/environ. Pass it per command instead, to the two commands that
# need it and nothing else.
#
# ⚠ The token goes to git through a credential helper reading it from the ENVIRONMENT, not
# through a https://x-access-token:<token>@github.com/... URL. A URL puts the credential in
# argv, where any local `ps` reads it, and git writes it into .git/config the moment anyone
# turns it into a remote. The helper text below contains the literal string `$GH_TOKEN`;
# the shell git runs it with expands it.
#
# ⚠ THE HELPER IS SCOPED TO github.com, and the scope is the point. An unscoped
# `credential.helper` never reads the `host=` git feeds it on stdin, so it answers for ANY
# host — point origin elsewhere and git hands over the token at the first 401. Verified:
# `printf 'protocol=https\nhost=other\n\n' | git -c credential.helper='!f...' credential fill`
# returns the token. `credential.https://github.com.helper` does not.
#
# `core.hooksPath=/dev/null` closes the last exec path in the push itself.
# ⚠ THIS IS THE ONE COMMAND THAT STAYS ROOT — no as_loop_user. The token exists only on
# this side of the privilege boundary, which is the whole of PET-408's fix.
#
# ⚠ IT PUSHES TO AN EXPLICIT URL, NOT TO `origin`, and that is not a style choice. Pushing
# to a named remote updates that remote's tracking ref, which would write into a
# claude-owned .git as root and break the next session with objects it cannot
# touch. Pushing to a URL updates no tracking ref, so root only READS the repository.
# It also means a session that repointed `origin` cannot redirect this push at all — the
# assertion above becomes defence in depth rather than the only guard.
#
# `safe.directory` is required because the repository is owned by another user and git
# refuses "dubious ownership" otherwise. Scoped to this one path, not `*`.
if ! GH_TOKEN="$TOKEN" git -C "$CHECKOUT" \
  -c "safe.directory=$CHECKOUT" \
  -c core.hooksPath=/dev/null \
  -c credential.helper= \
  -c 'credential.https://github.com.helper=!f(){ echo username=x-access-token; echo "password=$GH_TOKEN"; };f' \
  push --quiet "$EXPECT_REMOTE" "HEAD:refs/heads/$BRANCH" 2>"$TICK_DIR/push.err"; then
  fail_item "push failed: $(tr '\n' ' ' < "$TICK_DIR/push.err" | head -c 300)"
fi
log "pushed $BRANCH to $EXPECT_REMOTE"

# --draft is not a preference. A draft PR cannot be merged by anyone until a human marks it
# ready, which makes "the bot cannot merge" true through a second, independent mechanism
# besides branch protection. The prompt forbids the session from marking it ready; it has
# no token with which to do so either.
PR_BODY="$TICK_DIR/pr-body.md"
{
  printf 'Opened by the claude-247 work loop for **%s** — %s\n\n' "$ITEM" "$TITLE"
  printf 'This is a **draft**. The identity that opened it cannot approve or merge it, and the loop never marks a PR ready for review. A human reviews, marks it ready, and merges.\n\n'
  printf 'What the work item asked for, against what shipped, is in the comment below. Read that before the diff: the loop it replaces shipped a third of a spec behind a green check (PET-265), and this table is the check that was missing.\n\n'
  printf -- '- Work item: `%s`\n- Branch: `%s`\n- Session log stays on the host at `%s`\n' "$ITEM" "$BRANCH" "$TICK_DIR/session.log"
} > "$PR_BODY"

PR="$(GH_TOKEN="$TOKEN" gh pr create --repo "$REPO" --draft --base main --head "$BRANCH" \
  --title "${ITEM}: ${TITLE}" --body-file "$PR_BODY" 2>"$TICK_DIR/pr.err")" \
  || fail_item "gh pr create failed: $(tr '\n' ' ' < "$TICK_DIR/pr.err" | head -c 300)"
log "opened $PR"

# --- step 10: the closing comment ---------------------------------------------------------
# A comment rather than more body text, because the timeline is where a reviewer looks and
# because it keeps the diff-against-spec visibly separate from the bot's own summary of
# itself. A failure here does NOT fail the tick — the PR exists and is the thing that
# matters — but it is recorded, because a PR without this table is the exact artefact this
# loop is supposed to make impossible.
if GH_TOKEN="$TOKEN" gh pr comment "$PR" --repo "$REPO" --body-file "$SPEC_DIFF" >/dev/null 2>"$TICK_DIR/comment.err"; then
  record_claim worked "draft PR $PR with the spec diff"
  OUTCOME=worked
  DETAIL="$ITEM → $PR (${COMMITTED} files, spec diff posted)"
else
  record_claim worked "draft PR $PR, but the spec diff did not post"
  OUTCOME=worked
  DETAIL="$ITEM → $PR (${COMMITTED} files) — ⚠ the spec diff failed to post: $(tr '\n' ' ' < "$TICK_DIR/comment.err" | head -c 200). It is on the host at $SPEC_DIFF."
fi
exit 0
