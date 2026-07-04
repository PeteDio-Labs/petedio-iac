#!/usr/bin/env bash
# engine-run.sh — author ONE Bucket-B kind with the engine (Claude Code, Sonnet-tier). (PET-184)
#
# The ENGINE half of the three-agent fleet (PET-184). The worker adds additive catalog entries
# that REUSE an existing effect `kind`; the engine writes the NEW `kind` — its handler in the
# scoring/run engine + a tested exemplar entry + registering the kind into the property
# generators — which then flips that whole cluster to Bucket-A for the worker. Given a PET-<n>:
#
#   1. prepares a CLEAN `main` checkout of the target repo — the engine's OWN persistent per-task
#      clone (~/engine/work/PET-<n>), never a human's tree — OR, if a prior run of THIS task left
#      WIP on the branch (checkpoint/resume, 0e), reuses it instead of resetting;
#   2. writes the task spec + the engine per-task protocol to a prompt file (from --spec-file /
#      stdin — this script does NOT reach Linear; Claude/MCP or the caller supplies the spec);
#   3. AUTHORS via headless `claude -p` (pinned --model $ENGINE_MODEL), BOXED: a tight tool
#      allowlist (edit/read/test/local-git only — NO push, NO gh, NO merge tool; GH_TOKEN is not
#      in the agent's env), a bounded --max-turns and a hard `timeout`, and the GATE wired as a
#      Claude **Stop hook** (engine-gate.sh) so the engine cannot "finish" red;
#   4. INDEPENDENTLY re-runs the gate (engine-gate.sh: tsc → bun test → hardened property re-run)
#      as ground truth — never trust the agent's own "it's green";
#   5. commits (WIP-committing any uncompiled/red tree only as a resumable checkpoint, never as a
#      "done" PR), then the HARNESS — not the agent — pushes the branch (force-with-lease, ONLY
#      its own `pet-*` branch) and opens the PR as petedio-engine[bot] (DRAFT when the gate is red);
#   6. on a usage-cap hit: commits WIP, records the reset in the checkpoint sidecar, and exits
#      resumable (code 4) — the outer loop backs off to the reset and resumes this same task;
#   7. emits lifecycle events (scripts/agent-event.sh --agent engine) + appends an engine-runs.jsonl
#      eval row to MinIO.
#
# HARD RULES (mirror the worker's): the engine NEVER merges, never reviews, never touches Vault
# writes / TF state / live hosts, and only ever force-pushes its OWN `pet-*` branch. The reviewer
# (Opus, stronger) + Pedro are the downstream gates. Resumable unit = ONE kind per task.
#
# Usage:
#   scripts/engine/engine-run.sh PET-<n> --repo <owner/repo> \
#     [--spec-file <path> | --spec - ] [--slug <slug>] \
#     [--clone-dir <path>] [--fresh] [--dry-run] [--no-push]
#   echo "<spec>" | scripts/engine/engine-run.sh PET-209 --repo PeteDio-Labs/co-latro-backend --spec -
#
# Env (optional):
#   ENGINE_MODEL          pinned model (default: claude-sonnet-5 — the PET-184 decision; see the
#                         NB below). Must be a model the host's `claude` accepts AND weaker than
#                         the reviewer's Opus (review stays the stronger gate).
#   ENGINE_MAX_TURNS      headless turn cap (default: 40) — bounds cost if the Stop-hook gate
#                         keeps blocking an unfixable red.
#   ENGINE_TIMEOUT_S      hard wall-clock cap on the claude run (default: 3600).
#   ENGINE_MAX_THINKING_TOKENS  extended-thinking budget = the "low effort" lever (default: unset
#                         → Claude default; the loop pins it low). Passed as env to `claude`.
#   ENGINE_ALLOWED_TOOLS  the boxed tool allowlist (default below: edit/read/test/local-git only).
#   ENGINE_CLAUDE_CMD     claude binary (default: claude).
#   ENGINE_WORK_DIR       per-task clone parent (default: ~/engine/work).
#   ENGINE_STATE_DIR      checkpoint sidecar dir (default: ~/engine/state).
#   ENGINE_BASE           base branch (default: main).
#   ENGINE_AUTHOR_NAME/EMAIL  git identity for the engine's commit.
#   ENGINE_MC_ALIAS / ENGINE_RUNS_PATH  MinIO alias + key (default: homelab, agent-evals/engine-runs.jsonl).
#   GH_TOKEN              minted as petedio-engine[bot] via engine-mint-token.sh at PUSH time only
#                         (never exported into the agent's env). Never printed.
#
# NB (model id): PET-184 pins `claude-sonnet-5`. Validate it on the host once
# (`claude --model claude-sonnet-5 -p ok`); if that build isn't live, override ENGINE_MODEL /
# the agent_loop_engine_model Ansible var to the current Sonnet-tier id. This is a one-var change.
#
# Output (stdout): one JSON summary {issue,repo,branch,pr,tests,gate,tokens,wall_s,head_sha,phase}.
# Exit: 0 completed (PR opened, even draft-on-red) · 3 no-op (no change) · 4 paused (cap-hit,
# resumable) · non-zero otherwise = harness/tooling error.
set -euo pipefail

die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
info() { printf '\033[1;34m%s\033[0m\n' "$*" >&2; }

# --- arg parse --------------------------------------------------------------------------
ISSUE="" REPO="" SPEC_FILE="" SLUG="" CLONE_DIR="" FRESH=false DRY_RUN=false NO_PUSH=false
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --spec-file) SPEC_FILE="$2"; shift 2 ;;
    --spec) SPEC_FILE="$2"; shift 2 ;;          # alias; "-" = stdin
    --slug) SLUG="$2"; shift 2 ;;
    --clone-dir) CLONE_DIR="$2"; shift 2 ;;
    --fresh) FRESH=true; shift ;;               # force a clean-main reset even if WIP exists
    --dry-run) DRY_RUN=true; shift ;;
    --no-push) NO_PUSH=true; shift ;;
    -h | --help) sed -n '2,52p' "$0"; exit 0 ;;
    PET-*) ISSUE="$1"; shift ;;
    -*) die "unknown flag: $1 (see --help)" ;;
    *) die "unexpected arg: $1 (issue must be PET-<n>; see --help)" ;;
  esac
done

[[ "$ISSUE" =~ ^PET-[0-9]+$ ]] || die "first arg must be the issue PET-<n> (got '$ISSUE')."
[ -n "$REPO" ] || die "--repo <owner/repo> is required (e.g. PeteDio-Labs/co-latro-backend)."
NUM="${ISSUE#PET-}"

for t in git python3; do command -v "$t" >/dev/null || die "$t not in PATH."; done

ENGINE_MODEL="${ENGINE_MODEL:-claude-sonnet-5}"
ENGINE_MAX_TURNS="${ENGINE_MAX_TURNS:-40}"
ENGINE_TIMEOUT_S="${ENGINE_TIMEOUT_S:-3600}"
ENGINE_CLAUDE_CMD="${ENGINE_CLAUDE_CMD:-claude}"
HARNESS="${ENGINE_HARNESS:-claude-code-headless}"
BASE="${ENGINE_BASE:-main}"
AUTHOR_NAME="${ENGINE_AUTHOR_NAME:-agent-engine}"
AUTHOR_EMAIL="${ENGINE_AUTHOR_EMAIL:-agent-engine@petedio.local}"
WORK_DIR="${ENGINE_WORK_DIR:-$HOME/engine/work}"
STATE_DIR="${ENGINE_STATE_DIR:-$HOME/engine/state}"
# Boxed allowlist: implement + test + LOCAL git only. No `Bash(git push:*)`, no `Bash(gh:*)`,
# no arbitrary bash — the harness owns every origin-touching step, and GH_TOKEN is never in
# the agent's env, so the engine structurally cannot push, open a PR, or merge. COMMA-separated
# (never space) so specs with an internal space like `Bash(git add:*)` stay one token.
ENGINE_ALLOWED_TOOLS="${ENGINE_ALLOWED_TOOLS:-Read,Grep,Glob,Edit,Write,Bash(bun:*),Bash(git add:*),Bash(git commit:*),Bash(git status:*),Bash(git diff:*),Bash(git log:*),Bash(git restore:*),Bash(ls:*),Bash(cat:*),Bash(find:*)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SCRIPT_DIR/engine-gate.sh"
MINT="$SCRIPT_DIR/engine-mint-token.sh"
EVENT="$SCRIPT_DIR/../agent-event.sh"
[ -x "$GATE" ] || die "gate not found/executable: $GATE"

emit() { [ -x "$EVENT" ] && "$EVENT" --agent engine "$@" >/dev/null 2>&1 || true; }

# --- slug + branch ----------------------------------------------------------------------
[ -n "$SLUG" ] || SLUG="engine-pet-${NUM}"
SLUG="$(printf '%s' "$SLUG" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
BRANCH="pet-${NUM}-${SLUG}"
[[ "$BRANCH" =~ ^pet-[0-9]+- ]] || die "computed branch '$BRANCH' is not a pet-<n>-* branch — refusing."

emit --event run_started --issue "$ISSUE" --detail "$REPO"

# --- read the task spec (NOT from Linear — caller/Claude supplies it) --------------------
SPEC=""
if [ "$SPEC_FILE" = "-" ]; then SPEC="$(cat)"
elif [ -n "$SPEC_FILE" ]; then [ -f "$SPEC_FILE" ] || die "--spec-file not found: $SPEC_FILE"; SPEC="$(cat "$SPEC_FILE")"; fi
[ -n "$SPEC" ] || die "no task spec. Pass --spec-file <path> or --spec - (stdin). This script does NOT read Linear."

# --- artifact dir (OUTSIDE the worktree — prompt/settings/logs never get git-add'd) ------
ART="$(mktemp -d "${TMPDIR:-/tmp}/engine-art-${NUM}-XXXXXX")"

# --- checkpoint sidecar (0e) ------------------------------------------------------------
mkdir -p "$STATE_DIR"
STATE_FILE="$STATE_DIR/${ISSUE}.json"
# write_state <phase> [reset_at] — atomic temp+rename; never leaves a half-written sidecar.
write_state() {
  [ "$DRY_RUN" = true ] && return 0
  local phase="$1" reset_at="${2:-}"
  local tmp; tmp="$(mktemp "$STATE_DIR/.${ISSUE}.XXXXXX")"
  ISSUE="$ISSUE" REPO="$REPO" BRANCH="$BRANCH" PHASE="$phase" RESET_AT="$reset_at" \
    HEAD_SHA="${HEAD_SHA:-}" TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)" python3 <<'PY' >"$tmp"
import json, os
print(json.dumps({
    "issue": os.environ["ISSUE"], "repo": os.environ["REPO"], "branch": os.environ["BRANCH"],
    "phase": os.environ["PHASE"], "reset_at": os.environ["RESET_AT"] or None,
    "head_sha": os.environ["HEAD_SHA"] or None, "updated_at": os.environ["TS"],
}, separators=(",", ":")))
PY
  mv -f "$tmp" "$STATE_FILE"
}

# --- prepare the clone: resume WIP, else clean main -------------------------------------
[ -n "$CLONE_DIR" ] || { CLONE_DIR="$WORK_DIR/${ISSUE}"; mkdir -p "$WORK_DIR"; }

RESUMING=false
if [ -e "$CLONE_DIR/.git" ]; then
  _origin="$(git -C "$CLONE_DIR" remote get-url origin 2>/dev/null || true)"
  _norm="$(printf '%s' "$_origin" | sed -E 's#^git@github\.com:#https://github.com/#; s#\.git$##; s#/$##')"
  [ "$_norm" = "https://github.com/$REPO" ] || die "--clone-dir origin ('$_origin') is not $REPO — refusing to touch a foreign directory."
else
  info "cloning $REPO into $CLONE_DIR …"
  git clone --quiet "https://github.com/$REPO" "$CLONE_DIR" || die "clone of $REPO failed."
fi

cd "$CLONE_DIR"
git config user.name "$AUTHOR_NAME"
git config user.email "$AUTHOR_EMAIL"
# Never git-add the run's own scratch: keep Claude Code's local settings out of the tree.
grep -qxF '/.claude/' .git/info/exclude 2>/dev/null || printf '/.claude/\n' >>.git/info/exclude
git fetch --quiet origin "$BASE" || die "fetch origin/$BASE failed."

# Resume only if this exact task left in-progress WIP on its branch (0e) and --fresh wasn't asked.
if [ "$FRESH" = false ] && [ -f "$STATE_FILE" ] && git rev-parse --verify --quiet "$BRANCH" >/dev/null; then
  _phase="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("phase",""))' "$STATE_FILE" 2>/dev/null || true)"
  _ahead="$(git rev-list --count "origin/$BASE..$BRANCH" 2>/dev/null || echo 0)"
  if [ "$_phase" != "done" ] && [ "${_ahead:-0}" -gt 0 ]; then
    RESUMING=true
    git checkout --quiet "$BRANCH"
    info "RESUMING $ISSUE on $BRANCH ($_ahead WIP commit(s) ahead of $BASE, prior phase=$_phase)."
  fi
fi
if [ "$RESUMING" = false ]; then
  git checkout --quiet -B "$BASE" "origin/$BASE"
  [ "$DRY_RUN" = true ] || { git reset --hard --quiet "origin/$BASE"; git clean -fdq -e /.claude/; }
  git checkout --quiet -B "$BRANCH" "origin/$BASE"
fi
write_state authoring

emit --event issue_picked --issue "$ISSUE" --detail "$BRANCH"

cleanup() { rm -rf "$ART"; return 0; }   # the per-task clone PERSISTS (resumable); only $ART is scratch
trap cleanup EXIT

# --- build the engine prompt (spec + per-task protocol) ---------------------------------
PROMPT_FILE="$ART/engine-prompt-${NUM}.md"
{
  printf '# Engine task: %s\n\n' "$ISSUE"
  printf 'You are the ENGINE (PET-184): you implement ONE new effect `kind` for this Co-latro repo.\n\n'
  printf 'Per-task protocol — do ALL of it, in this repo only:\n'
  printf '1. Implement the new effect `kind` end to end: its type in the effect union, its handler\n'
  printf '   in the scoring/run engine, and any wiring it needs.\n'
  printf '2. Add ONE tested exemplar catalog entry that uses the new kind, with its mirrored test.\n'
  printf '3. Register the new kind into the property-test generators so the invariants cover it\n'
  printf '   (src/engine/**/*.property.test.ts — never-throws / output-shape / determinism /\n'
  printf '   round-trip / additive-invariance).\n'
  printf '4. The GATE (typecheck -> bun test -> hardened property re-run) MUST be green before you\n'
  printf '   finish. A Stop hook enforces this: you cannot end while it is red — fix the failure.\n\n'
  printf 'HARD RULES: additive to the catalog (never delete/overwrite sibling entries or tests).\n'
  printf 'Do NOT push, do NOT open a PR, do NOT touch git remotes, infra, Vault, or CI — the\n'
  printf 'harness does the push + PR. Commit your work locally as you go (WIP commits are the\n'
  printf 'checkpoint). Keep every committed tree compiling.\n\n'
  printf '## Spec\n\n%s\n' "$SPEC"
  [ "$RESUMING" = true ] && printf '\n## Resuming\nThis branch already has your earlier WIP commits — continue from there; do not restart.\n'
} >"$PROMPT_FILE"

# --- run-scoped Claude settings: wire the gate as a Stop hook (OUTSIDE the tree) ---------
SETTINGS_FILE="$ART/engine-settings-${NUM}.json"
GATE="$GATE" python3 <<'PY' >"$SETTINGS_FILE"
import json, os
print(json.dumps({
    "hooks": {
        # A RED gate exits 2 → blocks the engine from ending its turn, feeds the failure back.
        "Stop": [{"hooks": [{"type": "command", "command": os.environ["GATE"]}]}],
    },
}))
PY

# --- AUTHOR via boxed headless claude -p ------------------------------------------------
RUN_LOG="$ART/engine-run-${NUM}.json"
TOKENS=0; WALL_S=0; PHASE=authoring
if [ "$DRY_RUN" = true ]; then
  info "[dry-run] would author via '$ENGINE_CLAUDE_CMD -p' (model=$ENGINE_MODEL, max-turns=$ENGINE_MAX_TURNS, timeout=${ENGINE_TIMEOUT_S}s)"
else
  command -v "$ENGINE_CLAUDE_CMD" >/dev/null || die "$ENGINE_CLAUDE_CMD not in PATH (install via roles/agent-loop)."
  THINK_ENV=(); [ -n "${ENGINE_MAX_THINKING_TOKENS:-}" ] && THINK_ENV=(env "MAX_THINKING_TOKENS=$ENGINE_MAX_THINKING_TOKENS")
  # Hard wall-clock cap: GNU `timeout` on Linux/242, `gtimeout` (coreutils) on macOS, else none
  # (a missing wall is a soft degradation — --max-turns still bounds the run). rc 124 = timed out.
  TIMEOUT_PREFIX=()
  if command -v timeout >/dev/null; then TIMEOUT_PREFIX=(timeout "$ENGINE_TIMEOUT_S")
  elif command -v gtimeout >/dev/null; then TIMEOUT_PREFIX=(gtimeout "$ENGINE_TIMEOUT_S")
  else info "no timeout/gtimeout in PATH — running claude without a hard wall (--max-turns still bounds it)."; fi
  info "authoring: $ENGINE_CLAUDE_CMD -p  model=$ENGINE_MODEL  (boxed: no push/gh; gate=Stop hook)"
  START="$(date +%s)"
  set +e
  # GH_TOKEN deliberately NOT in this env. --output-format json → one final result object we parse.
  "${TIMEOUT_PREFIX[@]}" "${THINK_ENV[@]}" \
    "$ENGINE_CLAUDE_CMD" -p "$(cat "$PROMPT_FILE")" \
      --model "$ENGINE_MODEL" \
      --output-format json \
      --permission-mode acceptEdits \
      --max-turns "$ENGINE_MAX_TURNS" \
      --settings "$SETTINGS_FILE" \
      --allowedTools "$ENGINE_ALLOWED_TOOLS" \
      >"$RUN_LOG" 2>"$ART/engine-run-${NUM}.err"
  CRC=$?
  set -e
  END="$(date +%s)"; WALL_S=$((END - START))
  [ "$CRC" -eq 124 ] && info "claude -p hit the ${ENGINE_TIMEOUT_S}s timeout — continuing to gate/checkpoint the tree it left."
  [ "$CRC" -eq 0 ] || info "claude -p exited $CRC — continuing to gate/checkpoint the working tree."

  # Best-effort token total from the final JSON result object (usage.input+output).
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
    if isinstance(v,(int,float)): tot += int(v)
print(tot)
PY
)"
  [[ "$TOKENS" =~ ^[0-9]+$ ]] || TOKENS=0

  # --- CAP-HIT detection (0e): usage-cap = wait-to-reset; transient = short backoff -------
  # NB: read the combined log via an env-passed PATH, NOT a pipe — a `python3 <<'PY'` heredoc
  # is itself stdin, so a piped `cat | python3 <<PY` would silently discard the log (SC2259).
  CAPIN="$ART/engine-capscan-${NUM}.txt"
  cat "$RUN_LOG" "$ART/engine-run-${NUM}.err" >"$CAPIN" 2>/dev/null || true
  CAP="$(CAPIN="$CAPIN" python3 <<'PY'
import os, re
t = open(os.environ["CAPIN"], errors="replace").read().lower()
# Usage cap (wait until the window resets) vs transient overload (short backoff).
if re.search(r"usage limit reached|weekly limit|5-hour limit|quota (?:exceeded|reached)|limit will reset|resets? at", t):
    print("cap")
elif re.search(r"overloaded|rate.?limit|529|too many requests|please try again", t):
    print("transient")
else:
    print("")
PY
)"
  if [ "$CAP" = cap ]; then
    RESET_AT="$(grep -oiE 'resets? at[^.]*|[0-9]{1,2}(am|pm)|[0-9]{4}-[0-9]{2}-[0-9]{2}[t ][0-9:]+' "$CAPIN" 2>/dev/null | head -1 || true)"
    info "USAGE CAP hit — committing WIP and pausing (resumable). reset≈'${RESET_AT:-unknown}'."
    git add -A || true
    if ! git diff --cached --quiet; then git commit --quiet -m "wip(${ISSUE}): checkpoint before usage-cap pause"; fi
    HEAD_SHA="$(git rev-parse HEAD 2>/dev/null || true)"
    write_state paused_cap "$RESET_AT"
    emit --event cap_paused --issue "$ISSUE" --detail "usage-cap — resume after $RESET_AT"
    printf '{"issue":"%s","repo":"%s","branch":"%s","pr":null,"tests":"paused","gate":"paused","tokens":%s,"wall_s":%s,"head_sha":"%s","phase":"paused_cap"}\n' \
      "$ISSUE" "$REPO" "$BRANCH" "$TOKENS" "$WALL_S" "${HEAD_SHA:-}"
    exit 4
  fi
fi

# --- stage whatever the agent left; detect no-op ----------------------------------------
git add -A
_committed_ahead="$(git rev-list --count "origin/$BASE..HEAD" 2>/dev/null || echo 0)"
if git diff --cached --quiet && [ "${_committed_ahead:-0}" -eq 0 ]; then
  info "engine produced NO change (no commits, empty tree) — exiting without a PR."
  write_state "done"
  emit --event run_exited --issue "$ISSUE" --detail "no-change"
  printf '{"issue":"%s","repo":"%s","branch":"%s","pr":null,"tests":"none","gate":"n/a","tokens":%s,"wall_s":%s,"head_sha":null,"phase":"done"}\n' \
    "$ISSUE" "$REPO" "$BRANCH" "$TOKENS" "$WALL_S"
  exit 3
fi

# --- INDEPENDENT gate (ground truth — never trust the agent's self-report) --------------
GATE_VERDICT="red"; TESTS=fail
if [ "$DRY_RUN" = true ]; then
  info "[dry-run] skipping the independent gate."
  GATE_VERDICT="skipped"; TESTS=skipped
else
  info "independent gate (engine-gate.sh) — ground truth…"
  set +e
  "$GATE" "$CLONE_DIR" >"$ART/engine-gate-${NUM}.json" 2>"$ART/engine-gate-${NUM}.log"
  GRC=$?
  set -e
  cat "$ART/engine-gate-${NUM}.log" >&2 || true
  if [ "$GRC" -eq 0 ]; then GATE_VERDICT="green"; TESTS=pass
  elif [ "$GRC" -eq 2 ]; then GATE_VERDICT="red"; TESTS=fail
  else die "gate harness error (exit $GRC) — see the gate log."; fi
  info "gate verdict: $GATE_VERDICT"
fi

# --- commit (fold any uncommitted edits into a single engine commit; keep WIP on red) ----
if ! git diff --cached --quiet; then
  git commit --quiet -m "feat(${ISSUE}): new effect kind via ${HARNESS}/${ENGINE_MODEL}

Authored by the engine loop (PET-184). New Bucket-B effect kind + tested exemplar; gate=${GATE_VERDICT}.
${ISSUE}"
fi
HEAD_SHA="$(git rev-parse HEAD)"
[ "$GATE_VERDICT" = green ] && PHASE=ready || PHASE=gate_red
write_state "$PHASE"

# --- push (force-with-lease, OWN pet-* branch ONLY) + PR as petedio-engine[bot] ----------
PR_NUMBER="null"; PR_URL=""
if [ "$NO_PUSH" = true ] || [ "$DRY_RUN" = true ]; then
  info "skipping push/PR (${NO_PUSH:+--no-push }${DRY_RUN:+--dry-run})."
else
  # Mint the engine token HERE (never earlier — keeps it out of the agent's authoring env).
  if [ -z "${GH_TOKEN:-}" ]; then
    GH_TOKEN="$("$MINT" 2>/dev/null || true)"; export GH_TOKEN
    [ -n "$GH_TOKEN" ] || die "could not mint the petedio-engine[bot] token ($MINT). See docs/runbooks/engine-loop.md."
  fi
  command -v gh >/dev/null || die "gh not in PATH (needed to open the PR)."
  [[ "$BRANCH" =~ ^pet-[0-9]+- ]] || die "push guard: '$BRANCH' is not a pet-<n>-* branch — refusing."
  git push --quiet --force-with-lease origin "HEAD:$BRANCH" || die "push of $BRANCH failed (token push-scoped? branch protected?)."

  PR_TITLE="${ISSUE}: $(printf '%s' "$SPEC" | head -1 | cut -c1-60)"
  PR_BODY_FILE="$ART/engine-pr-body-${NUM}.md"
  {
    printf '## Engine PR — %s\n\n' "$ISSUE"
    printf 'Authored by the **engine loop** (PET-184): `%s` via `%s` (Bucket-B — a NEW effect kind).\n\n' "$ENGINE_MODEL" "$HARNESS"
    printf -- '- **Independent gate (tsc -> bun test -> property):** %s\n' "$GATE_VERDICT"
    printf -- '- **Head:** `%s`\n\n' "$HEAD_SHA"
    printf 'Once merged, this kind flips its cluster to Bucket-A for the worker. Mentions %s.\n' "$ISSUE"
    printf 'The engine NEVER merges — the reviewer (Opus) + Pedro decide.\n'
    printf '\n<sub>🤖 Engine loop on agent-loop-242 (PET-184). Draft = gate red.</sub>\n'
  } >"$PR_BODY_FILE"

  DRAFT_FLAG=(); [ "$GATE_VERDICT" != green ] && DRAFT_FLAG=(--draft)
  if PR_URL="$(gh pr create --repo "$REPO" --base "$BASE" --head "$BRANCH" \
        --title "$PR_TITLE" --body-file "$PR_BODY_FILE" "${DRAFT_FLAG[@]}" 2>/dev/null)"; then :
  else PR_URL="$(gh pr view "$BRANCH" --repo "$REPO" --json url --jq .url 2>/dev/null || true)"; fi
  if [ -n "$PR_URL" ]; then
    PR_NUMBER="$(gh pr view "$BRANCH" --repo "$REPO" --json number --jq .number 2>/dev/null || echo null)"
    info "PR: $PR_URL  (draft=$([ "$GATE_VERDICT" = green ] && echo no || echo yes))"
    emit --event pr_opened --issue "$ISSUE" --pr "$PR_NUMBER" --detail "gate=$GATE_VERDICT"
  fi
fi

# green + pushed = this task's resumable unit is done; a red PR stays gate_red for a resume pass.
[ "$GATE_VERDICT" = green ] && write_state "done"

# --- append the engine eval-log row (engine-runs.jsonl) ---------------------------------
LOG_DRY=""; { [ "$DRY_RUN" = true ] || [ "$NO_PUSH" = true ]; } && LOG_DRY="(dry — not uploaded)"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ROW="$(
  TS="$TS" ISSUE="$ISSUE" REPO="$REPO" BRANCH="$BRANCH" PR="$PR_NUMBER" MODEL="$ENGINE_MODEL" \
  HARNESS="$HARNESS" TESTS="$TESTS" GATE="$GATE_VERDICT" TOKENS="$TOKENS" \
  WALL_S="$WALL_S" HEAD_SHA="${HEAD_SHA:-}" python3 <<'PY'
import json, os
row = {
    "ts": os.environ["TS"], "issue": os.environ["ISSUE"], "repo": os.environ["REPO"],
    "branch": os.environ["BRANCH"],
    "pr": (None if os.environ["PR"] in ("null", "") else int(os.environ["PR"])),
    "engine_model": os.environ["MODEL"], "harness": os.environ["HARNESS"],
    "tests": os.environ["TESTS"], "guard": os.environ["GATE"],   # `guard`=gate verdict (fleet-view field)
    "tokens": int(os.environ["TOKENS"]), "wall_s": int(os.environ["WALL_S"]),
    "head_sha": os.environ["HEAD_SHA"],
}
print(json.dumps(row, separators=(",", ":"), ensure_ascii=False))
PY
)"
info "engine eval row $LOG_DRY: $ROW"
if [ "$DRY_RUN" = false ] && [ "$NO_PUSH" = false ] && command -v mc >/dev/null 2>&1; then
  ALIAS="${ENGINE_MC_ALIAS:-homelab}"; EPATH="${ENGINE_RUNS_PATH:-agent-evals/engine-runs.jsonl}"
  TARGET="${ALIAS}/${EPATH}"
  if mc alias list "$ALIAS" >/dev/null 2>&1; then
    TMP="$ART/engine-mc-${NUM}.tmp"
    if mc stat "$TARGET" >/dev/null 2>&1; then
      mc cat "$TARGET" >"$TMP" 2>/dev/null || true
      [ -s "$TMP" ] && [ "$(tail -c1 "$TMP")" != "" ] && printf '\n' >>"$TMP"
    fi
    printf '%s\n' "$ROW" >>"$TMP"
    mc pipe "$TARGET" <"$TMP" >/dev/null 2>&1 && info "eval row appended to $TARGET" || info "eval-row upload skipped (mc/alias issue)."
  fi
fi

# PET-221: a terminal gate-red means the new Bucket-B kind couldn't pass the ground-truth gate
# — a human needs to look. Flag the ISSUE (pipeline red); run_exited still follows so the engine
# status card reads idle (the loop moves to the next candidate), not falsely hung.
[ "$GATE_VERDICT" = red ] && emit --event escalated_needs_human --issue "$ISSUE" --pr "$([ "$PR_NUMBER" = null ] && echo '' || echo "$PR_NUMBER")" --detail "gate-red: Bucket-B kind needs human"
emit --event run_exited --issue "$ISSUE" --pr "$([ "$PR_NUMBER" = null ] && echo '' || echo "$PR_NUMBER")" --detail "gate=$GATE_VERDICT"

printf '{"issue":"%s","repo":"%s","branch":"%s","pr":%s,"tests":"%s","gate":"%s","tokens":%s,"wall_s":%s,"head_sha":"%s","phase":"%s"}\n' \
  "$ISSUE" "$REPO" "$BRANCH" "$PR_NUMBER" "$TESTS" "$GATE_VERDICT" "$TOKENS" "$WALL_S" "${HEAD_SHA:-}" "$([ "$GATE_VERDICT" = green ] && echo "done" || echo "$PHASE")"
