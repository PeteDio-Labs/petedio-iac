#!/usr/bin/env bash
# reviewer-loop.sh — one scheduled tick of the reviewer auto-launch (PET-247, S1).
#
# S0 → S1 for the REVIEWER half: until now the reviewer was a hand-started tmux Claude session
# (docs/runbooks/reviewer-loop.md), so worker/engine PRs opened unattended stalled at review
# (PET-219/PR #56 sat ~6h). This is the missing third auto-launch: a systemd timer fires each
# tick, the loop picks at most ONE reviewable PR, and launches a BOXED one-PR `claude -p`
# reviewer run. The reviewer OUTRANKS the engine on the shared Max quota (Pedro > reviewer >
# engine): it takes the same cc-slot flock the engine uses AND holds the REVIEWER_ACTIVE
# sentinel while working so queued engine ticks yield.
#
# Per tick:
#   1. guards — PAUSED sentinel · single-instance lock · cc-slot flock (shared with engine);
#   2. poll reviewer-candidates.sh (open, non-draft, not-own Co-latro PRs + PET key);
#   3. bash-side reviewability gates (quota-free — a tick with nothing to review costs $0):
#        a. PET key parsed;
#        b. NOT already reviewed at the PR's current head by $REVIEWER_BOT_LOGIN (gh);
#        c. Linear issue state == "In Review" (read-only GraphQL, key self-served from Vault
#           exactly like worker-candidates.sh; no reachable key → park, protocol gate intact);
#        d. per-PR launch cooldown (rides out label/status propagation lag);
#   4. launch ONE boxed `claude -p` with the one-PR reviewer protocol (pinned model,
#      --max-turns + hard timeout, tool allowlist); emit run_started/run_exited events;
#   5. verify ground truth afterwards via gh: did a review by the bot actually post?
#
# The heavy judgment (diff vs CLAUDE.md, findings, approve/changes) stays Claude's — the loop
# only decides "is there exactly one PR worth spending quota on". HARD RULES ride in the
# prompt: never merge, never change Linear status, never review own PRs, no secrets in output.
#
# Usage:  reviewer-loop.sh            one tick (the systemd timer's ExecStart)
#         reviewer-loop.sh status     candidates + recent launches (read-only)
# Env: REVIEWER_HOME (~/reviewer) · REVIEWER_LAUNCH_COOLDOWN_MIN (60) · REVIEWER_MODEL
#      (claude-opus-4-8) · REVIEWER_CLAUDE_CMD (claude) · REVIEWER_MAX_TURNS (60) ·
#      REVIEWER_TIMEOUT_S (2400) · REVIEWER_ALLOWED_TOOLS · REVIEWER_BOT_LOGIN
#      (petedio-reviewer[bot]) · REVIEWER_LINEAR_VAULT_PATH (kv/services/linear) ·
#      ENGINE_HOME (~/engine — for the REVIEWER_ACTIVE sentinel) · ENGINE_SLOT_LOCK
#      (/run/lock/cc-slot) · plus the REVIEWER_REPOS/REVIEWER_SELF_LOGIN vars
#      reviewer-candidates.sh honors.
set -uo pipefail
log() { printf '\033[1;34m[reviewer-loop] %s\033[0m\n' "$*" >&2; }
die() { printf '\033[1;31m[reviewer-loop] ERROR: %s\033[0m\n' "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CANDIDATES="$SCRIPT_DIR/reviewer-candidates.sh"
EVENT="$SCRIPT_DIR/../agent-event.sh"
[ -x "$CANDIDATES" ] || die "reviewer-candidates.sh not found/executable."
command -v gh >/dev/null || die "gh not in PATH."
command -v python3 >/dev/null || die "python3 not in PATH."

REVIEWER_HOME="${REVIEWER_HOME:-$HOME/reviewer}"
PAUSE_FILE="$REVIEWER_HOME/PAUSED"
LAUNCH_DIR="$REVIEWER_HOME/launched"
LOCK="$REVIEWER_HOME/reviewer-loop.lock"
ART="$REVIEWER_HOME/artifacts"
COOLDOWN_MIN="${REVIEWER_LAUNCH_COOLDOWN_MIN:-60}"
MODEL="${REVIEWER_MODEL:-claude-opus-4-8}"
CLAUDE_CMD="${REVIEWER_CLAUDE_CMD:-claude}"
MAX_TURNS="${REVIEWER_MAX_TURNS:-60}"
TIMEOUT_S="${REVIEWER_TIMEOUT_S:-2400}"
# Bash/Read for scripts + gh; MCP for the Linear comment + agent-reviewed label. The reviewer
# bot token (contents:read + pr:write, minted inside reviewer-mint-token.sh) cannot merge or
# push, which bounds Bash regardless of the allowlist.
ALLOWED_TOOLS="${REVIEWER_ALLOWED_TOOLS:-Bash,Read,Grep,Glob,mcp__*}"
BOT_LOGIN="${REVIEWER_BOT_LOGIN:-petedio-reviewer[bot]}"
VAULT_PATH="${REVIEWER_LINEAR_VAULT_PATH:-kv/services/linear}"
ENGINE_HOME="${ENGINE_HOME:-$HOME/engine}"
REVIEWER_ACTIVE="$ENGINE_HOME/REVIEWER_ACTIVE"
SLOT_LOCK="${ENGINE_SLOT_LOCK:-/run/lock/cc-slot}"
mkdir -p "$LAUNCH_DIR" "$ART"

emit() { [ -x "$EVENT" ] && "$EVENT" --agent reviewer "$@" >/dev/null 2>&1 || true; }

# --- status subcommand (read-only) ------------------------------------------------------
if [ "${1:-}" = status ]; then
  echo "candidates (pre-gate):"
  "$CANDIDATES" 2>/dev/null | python3 -c 'import json,sys
try: [print("  %-9s %s#%s  %s" % (c.get("pet") or "?", c.get("repo","").split("/")[-1], c.get("number"), (c.get("title") or "")[:55])) for c in json.load(sys.stdin)]
except Exception: print("  (none / gh unreachable)")' 2>/dev/null || echo "  (none / gh unreachable)"
  echo "recent launches:"; ls -1t "$LAUNCH_DIR" 2>/dev/null | head -8 | sed 's/^/  /' || true
  exit 0
fi
[ $# -eq 0 ] || die "unknown subcommand '$1' (use: <none> | status)."

# --- guard 1: pause sentinel ------------------------------------------------------------
[ -e "$PAUSE_FILE" ] && { log "PAUSED sentinel present ($PAUSE_FILE) — parking."; exit 0; }

# --- guard 2: single-instance lock ------------------------------------------------------
exec 8>"$LOCK" || die "cannot open lock file $LOCK."
flock -n 8 || { log "another reviewer tick holds the lock — exiting."; exit 0; }

# --- poll candidates (cheap, gh-only) ---------------------------------------------------
CANDS="$("$CANDIDATES" 2>/dev/null || echo '[]')"
COUNT="$(printf '%s' "$CANDS" | python3 -c 'import json,sys
try: print(len(json.load(sys.stdin)))
except Exception: print(0)' 2>/dev/null || echo 0)"
[ "${COUNT:-0}" -gt 0 ] || { log "no open worker/engine PRs — idle."; exit 0; }

# --- resolve the read-only Linear key (worker-candidates.sh precedent; never printed) ----
LINEAR_KEY="${LINEAR_API_KEY:-}"
if [ -z "$LINEAR_KEY" ] && command -v vault >/dev/null 2>&1 && [ -n "${VAULT_ADDR:-}" ]; then
  LINEAR_KEY="$(vault kv get -field=api_key "$VAULT_PATH" 2>/dev/null || true)"
fi
if [ -z "$LINEAR_KEY" ]; then
  log "no Linear key reachable ($VAULT_PATH) — cannot verify the In-Review gate; parking."
  exit 0
fi

# --- bash-side gates → pick the oldest reviewable PR -------------------------------------
NOW="$(date +%s)"; COOLDOWN_S=$((COOLDOWN_MIN * 60))
PICK=""
while IFS=$'\t' read -r REPO NUM PET HEADREF; do
  [ -n "$REPO" ] || continue
  MARKER="$LAUNCH_DIR/${REPO##*/}#${NUM}"
  if [ -e "$MARKER" ] && [ $((NOW - $(stat -c %Y "$MARKER" 2>/dev/null || stat -f %m "$MARKER"))) -lt "$COOLDOWN_S" ]; then
    log "$REPO#$NUM launched within the ${COOLDOWN_MIN}m cooldown — skipping."; continue
  fi
  [ -n "$PET" ] && [ "$PET" != None ] || { log "$REPO#$NUM has no PET key — skipping."; continue; }
  # gate b: already reviewed at the current head by the bot? (robust dedup, label-independent)
  HEAD_SHA="$(gh pr view "$NUM" --repo "$REPO" --json headRefOid -q .headRefOid 2>/dev/null || true)"
  REVIEWED="$(gh api "repos/$REPO/pulls/$NUM/reviews" 2>/dev/null | BOT="$BOT_LOGIN" HEAD="$HEAD_SHA" python3 -c 'import json,os,sys
try: rs=json.load(sys.stdin)
except Exception: rs=[]
bot=os.environ["BOT"]; head=os.environ["HEAD"]
print(any((r.get("user") or {}).get("login")==bot and (not head or r.get("commit_id")==head) for r in rs))' || echo True)"
  [ "$REVIEWED" = False ] || { log "$REPO#$NUM already reviewed by $BOT_LOGIN at head — skipping."; continue; }
  # gate c: Linear protocol — the issue must be In Review (the reviewer never forces status)
  STATE="$(LINEAR_KEY="$LINEAR_KEY" PET="$PET" python3 <<'PY'
import json, os, urllib.request
num = os.environ["PET"].split("-")[1]
q = {"query": 'query($n:Float){issues(filter:{team:{key:{eq:"PET"}},number:{eq:$n}}){nodes{state{name}}}}',
     "variables": {"n": float(num)}}
req = urllib.request.Request("https://api.linear.app/graphql", json.dumps(q).encode(),
    {"Content-Type": "application/json", "Authorization": os.environ["LINEAR_KEY"]})
try:
    nodes = json.load(urllib.request.urlopen(req, timeout=15))["data"]["issues"]["nodes"]
    print(nodes[0]["state"]["name"] if nodes else "")
except Exception:
    print("")
PY
)"
  if [ "$STATE" != "In Review" ]; then
    log "$REPO#$NUM ($PET) is '${STATE:-unknown}', not In Review — protocol gate; skipping."
    continue
  fi
  PICK="$REPO"$'\t'"$NUM"$'\t'"$PET"
  break
done < <(printf '%s' "$CANDS" | python3 -c 'import json,sys
for c in sorted(json.load(sys.stdin), key=lambda c: (c.get("repo",""), c.get("number") or 0)):
    print("\t".join([str(c.get("repo","")), str(c.get("number","")), str(c.get("pet") or ""), str(c.get("headRefName",""))]))')

[ -n "$PICK" ] || { log "no reviewable PR passed the gates — idle."; exit 0; }
REPO="$(printf '%s' "$PICK" | cut -f1)"; NUM="$(printf '%s' "$PICK" | cut -f2)"; PET="$(printf '%s' "$PICK" | cut -f3)"

# --- guard 3: cc-slot flock (ONE automated Claude Code session on this host) --------------
if ! exec 9>"$SLOT_LOCK" 2>/dev/null; then
  SLOT_LOCK="$ENGINE_HOME/cc-slot.lock"; exec 9>"$SLOT_LOCK" || die "cannot open a cc-slot lock file."
fi
flock -n 9 || { log "cc-slot busy (engine or another reviewer run) — will retry next tick."; exit 0; }
log "cc-slot acquired ($SLOT_LOCK)."

# --- launch: sentinel (engine yields) + marker (cooldown) + boxed one-PR claude run -------
touch "$REVIEWER_ACTIVE" 2>/dev/null || true
trap 'rm -f "$REVIEWER_ACTIVE"' EXIT
touch "$LAUNCH_DIR/${REPO##*/}#${NUM}"

PROMPT_FILE="$ART/reviewer-prompt-${PET}-${NUM}.md"
cat >"$PROMPT_FILE" <<EOF
You are the REVIEWER half of the agent fleet on this host, running as a BOXED one-shot.
HARD RULES (bind you): never merge; never change Linear status; never review your own PRs;
no apply/import/state; no SSH to live hosts; never print secrets.

Review EXACTLY ONE PR this run: **$REPO#$NUM** (Linear issue $PET). The launcher already
verified: the issue is In Review, and no $BOT_LOGIN review exists at the current head.

Work from this repo checkout (cwd). Steps:
1. scripts/reviewer/reviewer-checkout-test.sh $REPO $NUM  — GROUND TRUTH tests; never
   substitute the PR author's claim.
2. gh pr diff $NUM --repo $REPO — read the full diff against the target repo's CLAUDE.md and
   conventions; read the PR body's verification-evidence block if present.
3. Round-trips: scripts/reviewer/reviewer-round-trips.sh $REPO $NUM. If this review would be
   the 3rd round-trip, post a needs-human PR comment instead of a verdict and stop.
4. Fill scripts/reviewer/templates/pr-verdict.md.tmpl and post the review as $BOT_LOGIN:
   GH_TOKEN="\$(scripts/reviewer/reviewer-mint-token.sh)" gh pr review $NUM --repo $REPO \\
     --approve|--request-changes --body-file <file>
5. Fill scripts/reviewer/templates/linear-verdict.md.tmpl, post it as a comment on $PET via
   the Linear MCP, and set the label agent-reviewed (+ changes-requested when requesting
   changes). DO NOT change the issue status. If the Linear MCP is unavailable in this
   headless run, note that in the PR review body and continue — the verdict and eval row are
   the must-haves.
6. Append the eval row (this also emits the verdict lifecycle event):
   scripts/reviewer/reviewer-log-verdict.sh --issue $PET --pr $NUM \\
     --worker-tests pass|fail --claude-verdict approve|changes --findings-json '[...]' \\
     --worker-model <from the PR> --harness <from the PR> \\
     --reviewer-model $MODEL --round-trips <n>
Anything ambiguous or risky: comment on the PR and stop. Do not pick up any other PR.
EOF

TIMEOUT_PREFIX=()
if command -v timeout >/dev/null; then TIMEOUT_PREFIX=(timeout "$TIMEOUT_S")
elif command -v gtimeout >/dev/null; then TIMEOUT_PREFIX=(gtimeout "$TIMEOUT_S"); fi

emit --event run_started --issue "$PET" --pr "$NUM" --detail "auto-launch review $REPO#$NUM"
log "launching boxed review: $REPO#$NUM ($PET)  model=$MODEL max-turns=$MAX_TURNS timeout=${TIMEOUT_S}s"
RUN_LOG="$ART/reviewer-run-${PET}-${NUM}.json"
START_S="$(date +%s)"
set +e
"${TIMEOUT_PREFIX[@]}" "$CLAUDE_CMD" -p "$(cat "$PROMPT_FILE")" \
  --model "$MODEL" \
  --output-format json \
  --permission-mode acceptEdits \
  --max-turns "$MAX_TURNS" \
  --allowedTools "$ALLOWED_TOOLS" \
  >"$RUN_LOG" 2>"$ART/reviewer-run-${PET}-${NUM}.err"
CRC=$?
set -e
[ "$CRC" -eq 124 ] && log "claude -p hit the ${TIMEOUT_S}s wall — verifying what it managed."
WALL_S=$(( $(date +%s) - START_S ))

# --- PET-258: stamp real usage onto the row the run just logged --------------------------
# The verdict row is appended by the boxed claude run ITSELF, which cannot know its final
# usage — but the result JSON here does. Same token convention as engine-run.sh
# (input + output + cache_creation + cache_read). Best-effort: a missing/garbled result
# object just leaves tokens at 0, never blocks the tick.
TOKENS="$(RUN_LOG="$RUN_LOG" python3 <<'PY'
import json, os
tot = 0
try:
    obj = json.load(open(os.environ["RUN_LOG"]))
except Exception:
    obj = {}
u = (obj or {}).get("usage") or {}
for k in ("input_tokens","output_tokens","cache_creation_input_tokens","cache_read_input_tokens"):
    v = u.get(k)
    if isinstance(v, (int, float)): tot += int(v)
print(tot)
PY
)"
if [ "${TOKENS:-0}" -gt 0 ]; then
  "$SCRIPT_DIR/reviewer-stamp-usage.sh" --issue "$PET" --pr "$NUM" \
    --tokens "$TOKENS" --wall-s "$WALL_S" 2>&1 | tail -1 >&2 || true
  log "usage: tokens=$TOKENS wall_s=${WALL_S}s (stamped onto the verdict row)."
else
  log "usage: no token count in $RUN_LOG (rc=$CRC) — row keeps tokens=0."
fi

# --- ground truth: did a review by the bot actually post? --------------------------------
VERDICT="$(gh api "repos/$REPO/pulls/$NUM/reviews" 2>/dev/null | BOT="$BOT_LOGIN" python3 -c 'import json,os,sys
try: rs=json.load(sys.stdin)
except Exception: rs=[]
bot=os.environ["BOT"]
states=[r.get("state","") for r in rs if (r.get("user") or {}).get("login")==bot]
print(states[-1].lower() if states else "none")' || echo none)"
emit --event run_exited --issue "$PET" --pr "$NUM" --detail "verdict=$VERDICT rc=$CRC"
log "$REPO#$NUM done — bot verdict on GitHub: $VERDICT (claude rc=$CRC)."
[ "$VERDICT" != none ] || log "NO verdict posted — inspect $RUN_LOG / .err (left in $ART)."
exit 0
