#!/usr/bin/env bash
# worker-run.sh — author one Co-latro issue with the 8B worker model (PET-179).
#
# The WORKER half of the two-agent system (PET-179), the core wrapper. Given a PET-<n>, it:
#   1. resets a CLEAN `main` checkout of the target Co-latro repo (its OWN clone, never a
#      human's working tree);
#   2. writes the task spec to a prompt file (the issue body, supplied via --spec-file or
#      stdin — this script does NOT reach Linear; Claude/MCP or the caller supplies the spec);
#   3. AUTHORS the change (WORKER_AUTHOR_MODE):
#        * `patch` (DEFAULT, PET-182) — the constrained single-shot patch-apply core
#          (worker-patch-author.sh, qwen2.5-coder:7b): the only path local models author
#          reliably. Deterministic anchor-insert of an additive catalog entry + mirrored test.
#        * `opencode` (legacy) — `opencode run --pure -m <model>` agentic editing (PET-133).
#          Kept for the record; local models do NOT author through it (template tool-call gap).
#      Either way we capture wall time (and, for opencode, best-effort tokens);
#   4. creates branch `pet-<n>-<slug>`;
#   5. runs the GUARDRAIL (scripts/worker/worker-guard-additive.sh) on the diff — a net drop
#      in catalog entries / test cases (the 8B overwrite-not-append failure) BLOCKS the run;
#   6. runs `bun install` + `bun test` (the host now has a local Postgres, PET-178, so the
#      suite is green at baseline — a failure here is REAL);
#   7. pushes the branch (force-with-lease, ONLY its own `pet-*` branch — never a human's);
#   8. opens a **DRAFT** PR when tests fail, a normal PR when green;
#   9. emits lifecycle events via scripts/agent-event.sh (run_started → issue_picked →
#      pr_opened → run_exited) and appends a worker eval-log row.
#
# HARD RULES (mirrors the reviewer's): the worker NEVER merges, never reviews, never touches
# Vault writes / TF state / live hosts, and only ever force-pushes its OWN `pet-*` branch.
# Idempotent: re-running for the same PET re-resets to main and recreates the branch.
#
# Usage:
#   scripts/worker/worker-run.sh PET-<n> --repo <owner/repo> \
#     [--spec-file <path> | --spec - ] [--slug <slug>] \
#     [--clone-dir <path>] [--dry-run] [--no-push]
#   # spec on stdin:
#   echo "<task spec>" | scripts/worker/worker-run.sh PET-74 --repo PeteDio-Labs/co-latro-backend --spec -
#
# Env (optional):
#   WORKER_MODEL          harness model (default: ollama/gemma4:e4b).
#   WORKER_OPENCODE_CMD   base opencode invocation (default: "opencode run --pure").
#   WORKER_HARNESS        harness name for the eval row (default: opencode).
#   WORKER_BASE           base branch (default: main).
#   WORKER_INSTALL_CMD    install command (default: "bun install").
#   WORKER_TEST_CMD       test command (default: "bun test").
#   WORKER_AUTHOR_NAME/EMAIL  git identity for the worker's commit.
#   GH_TOKEN              GitHub auth (push + open-PR scope, NO merge). If unset, minted as
#                         the petedio-worker[bot] App token via worker-mint-token.sh
#                         (PET-176). Never printed.
#
# Output (stdout): one JSON summary {issue,repo,branch,pr,tests,guard,tokens,wall_s,head_sha}.
# Exit 0 on a completed run (PR opened, even draft-on-fail); non-zero only on a HARNESS error
# (clone/guard-block/tooling) — the guard block is exit 3 specifically.
set -euo pipefail

die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
info() { printf '\033[1;34m%s\033[0m\n' "$*" >&2; }

# --- arg parse --------------------------------------------------------------------------
ISSUE="" REPO="" SPEC_FILE="" SLUG="" CLONE_DIR="" DRY_RUN=false NO_PUSH=false
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --spec-file) SPEC_FILE="$2"; shift 2 ;;
    --spec) SPEC_FILE="$2"; shift 2 ;;          # alias; "-" = stdin
    --slug) SLUG="$2"; shift 2 ;;
    --clone-dir) CLONE_DIR="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --no-push) NO_PUSH=true; shift ;;
    -h | --help) sed -n '2,45p' "$0"; exit 0 ;;
    PET-*) ISSUE="$1"; shift ;;
    -*) die "unknown flag: $1 (see --help)" ;;
    *) die "unexpected arg: $1 (issue must be PET-<n>; see --help)" ;;
  esac
done

[[ "$ISSUE" =~ ^PET-[0-9]+$ ]] || die "first arg must be the issue PET-<n> (got '$ISSUE')."
[ -n "$REPO" ] || die "--repo <owner/repo> is required (e.g. PeteDio-Labs/co-latro-backend)."
NUM="${ISSUE#PET-}"

for t in gh git python3; do command -v "$t" >/dev/null || die "$t not in PATH."; done

# Authoring mode: `patch` (constrained patch-apply, the working path) is the DEFAULT; `opencode`
# is the legacy agentic path (kept for the record — local models can't author through it).
AUTHOR_MODE="${WORKER_AUTHOR_MODE:-patch}"
if [ "$AUTHOR_MODE" = patch ]; then
  MODEL="${WORKER_MODEL:-ollama/qwen2.5-coder:7b}"
  HARNESS="${WORKER_HARNESS:-patch-apply}"
else
  MODEL="${WORKER_MODEL:-ollama/gemma4:e4b}"
  HARNESS="${WORKER_HARNESS:-opencode}"
fi
OPENCODE_CMD="${WORKER_OPENCODE_CMD:-opencode run --pure}"
OLLAMA_URL="${WORKER_OLLAMA_URL:-http://192.168.50.12:11434}"
BASE="${WORKER_BASE:-main}"
INSTALL_CMD="${WORKER_INSTALL_CMD:-bun install}"
TEST_CMD="${WORKER_TEST_CMD:-bun test}"
AUTHOR_NAME="${WORKER_AUTHOR_NAME:-agent-worker}"
AUTHOR_EMAIL="${WORKER_AUTHOR_EMAIL:-agent-worker@petedio.local}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/worker-guard-additive.sh"
AUTHOR="$SCRIPT_DIR/worker-patch-author.sh"   # constrained patch-apply authoring core (patch mode)
EVENT="$SCRIPT_DIR/../agent-event.sh"
[ -x "$GUARD" ] || die "guardrail not found/executable: $GUARD"
[ "$AUTHOR_MODE" != patch ] || [ -x "$AUTHOR" ] || die "patch authoring core not found/executable: $AUTHOR"

# emit() — best-effort lifecycle event; a telemetry failure must NEVER fail the run.
emit() { [ -x "$EVENT" ] && "$EVENT" --agent worker "$@" >/dev/null 2>&1 || true; }

# --- token (never printed) — env first, else Vault, mirroring rebase-loop-prs.sh --------
# Mint the petedio-worker[bot] App token on demand (PET-176): push + open-PR scope,
# structurally cannot merge. Nothing long-lived on the host (1-hour installation token).
# An already-set GH_TOKEN (e.g. a test PAT) wins, so this only mints when unset.
if [ -z "${GH_TOKEN:-}" ] && [ "$DRY_RUN" = false ]; then
  GH_TOKEN="$("$SCRIPT_DIR/worker-mint-token.sh" 2>/dev/null || true)"
  export GH_TOKEN
  [ -n "$GH_TOKEN" ] || die "could not mint the petedio-worker[bot] token (worker-mint-token.sh). See docs/runbooks/worker-loop.md."
fi

# --- slug + branch ----------------------------------------------------------------------
if [ -z "$SLUG" ]; then
  SLUG="worker-pet-${NUM}"   # fallback; prefer passing --slug from the Linear branch name.
fi
# Sanitize the slug to the branch-safe charset and the loop prefix invariant.
SLUG="$(printf '%s' "$SLUG" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
BRANCH="pet-${NUM}-${SLUG}"
# INVARIANT (the worker only ever touches its own pet-* branch): refuse anything else.
[[ "$BRANCH" =~ ^pet-[0-9]+- ]] || die "computed branch '$BRANCH' is not a pet-<n>-* branch — refusing."

emit --event run_started --issue "$ISSUE" --detail "$REPO"

# --- read the task spec (NOT from Linear — caller/Claude supplies it) --------------------
SPEC=""
if [ "$SPEC_FILE" = "-" ]; then
  SPEC="$(cat)"
elif [ -n "$SPEC_FILE" ]; then
  [ -f "$SPEC_FILE" ] || die "--spec-file not found: $SPEC_FILE"
  SPEC="$(cat "$SPEC_FILE")"
fi
[ -n "$SPEC" ] || die "no task spec given. Pass --spec-file <path> or --spec - (stdin). This script does NOT read Linear; the spec comes from the issue body via Claude/MCP or the caller."

# --- artifact dir (OUTSIDE the worktree) ------------------------------------------------
# Every .worker-* file the run produces (prompt, harness log, guard output, test log, PR
# body, mc temp) lives HERE, never in the clone — the harness log can contain arbitrary
# model stdout, and `git add -A` must only ever stage the harness's real code change, never
# one of ours. Removed on exit alongside the clone.
ART="$(mktemp -d "${TMPDIR:-/tmp}/worker-art-${NUM}-XXXXXX")"

# --- clean main checkout (the worker's OWN clone) ---------------------------------------
# Default to a throwaway /tmp clone so a bare invocation never disturbs a live working tree.
# A persistent --clone-dir is supported for the loop's pre-cloned workspace — but we REFUSE
# to hard-reset a path that isn't a CLEAN clone of THIS repo (the LXC-113 rule: never destroy
# un-versioned work). Either way each run starts from a clean origin/$BASE.
OWN_CLONE=false
if [ -z "$CLONE_DIR" ]; then
  CLONE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/worker-${NUM}-XXXXXX")/repo"
  OWN_CLONE=true
  info "cloning $REPO fresh into $CLONE_DIR …"
  gh repo clone "$REPO" "$CLONE_DIR" >/dev/null 2>&1 || die "clone of $REPO failed (auth? repo exists?)."
elif [ ! -e "$CLONE_DIR/.git" ]; then
  # Provided path that isn't a clone yet → clone into it (caller-owned; not removed on exit).
  info "cloning $REPO into $CLONE_DIR …"
  gh repo clone "$REPO" "$CLONE_DIR" >/dev/null 2>&1 || die "clone of $REPO into $CLONE_DIR failed."
else
  # Provided EXISTING checkout — it MUST be a clean clone of $REPO before we reset/clean it.
  _origin="$(git -C "$CLONE_DIR" remote get-url origin 2>/dev/null || true)"
  _norm="$(printf '%s' "$_origin" | sed -E 's#^git@github\.com:#https://github.com/#; s#\.git$##; s#/$##')"
  [ "$_norm" = "https://github.com/$REPO" ] ||
    die "--clone-dir origin ('$_origin') is not $REPO — refusing to reset a foreign directory."
  _dirty="$(git -C "$CLONE_DIR" status --porcelain --untracked-files=all | grep -vE '(^|/)\.worker-' || true)"
  [ -z "$_dirty" ] ||
    die "refusing to reset $CLONE_DIR: it has uncommitted/untracked changes. Hand the worker a CLEAN clone (LXC-113 rule: never destroy un-versioned work)."
fi
cleanup() {
  rm -rf "$ART"
  [ "$OWN_CLONE" = true ] && rm -rf "$(dirname "$CLONE_DIR")"
  return 0
}
trap cleanup EXIT

cd "$CLONE_DIR"
git config user.name "$AUTHOR_NAME"
git config user.email "$AUTHOR_EMAIL"
git fetch --quiet origin "$BASE" || die "fetch origin/$BASE failed."
git checkout --quiet -B "$BASE" "origin/$BASE"
# Discard any prior in-flight state — skipped under --dry-run so a preview never mutates the
# clone (and the clean-clone validation above already ruled out destroying real work).
if [ "$DRY_RUN" = false ]; then
  git reset --hard --quiet "origin/$BASE"
  git clean -fdq
fi

emit --event issue_picked --issue "$ISSUE" --detail "$BRANCH"

# Branch off clean main.
git checkout --quiet -B "$BRANCH" "origin/$BASE"

# --- write the prompt file + build the harness task -------------------------------------
PROMPT_FILE="$ART/.worker-prompt-${NUM}.md"
{
  printf '# Task: %s\n\n' "$ISSUE"
  printf 'You are the WORKER. Implement ONLY this Co-latro issue in this repo. ADD content/tests;\n'
  printf 'NEVER delete or overwrite existing catalog entries or test cases (the change is additive).\n'
  printf 'Run nothing destructive. Do not touch infra, Vault, or CI.\n\n'
  printf '## Spec\n\n%s\n' "$SPEC"
} >"$PROMPT_FILE"
# (No .gitignore juggling needed — PROMPT_FILE and every other .worker-* artifact lives in
# $ART, outside the worktree, so `git add -A` can never stage them.)

TASK="$(cat "$PROMPT_FILE")"

# --- AUTHOR the change (patch-apply by default; opencode legacy) -------------------------
RUN_LOG="$ART/.worker-run-${NUM}.log"
TOKENS=0
WALL_S=0
if [ "$DRY_RUN" = true ]; then
  info "[dry-run] would author via '$AUTHOR_MODE' (model=$MODEL)"
elif [ "$AUTHOR_MODE" = patch ]; then
  # Constrained patch-apply authoring (PET-182): the path local models author reliably.
  # The author mutates the clone's working tree in place; we then guard/test/push it below.
  command -v curl >/dev/null || die "curl not in PATH (patch authoring)."
  SPEC_RAW="$ART/.worker-spec-${NUM}.md"
  printf '%s\n' "$SPEC" >"$SPEC_RAW"
  AUTHOR_TAG="${MODEL#ollama/}"                  # author wants the bare ollama tag
  info "authoring (patch-apply): model=$AUTHOR_TAG ollama=$OLLAMA_URL"
  START="$(date +%s)"
  set +e
  SPEC_FILE="$SPEC_RAW" OLLAMA_URL="$OLLAMA_URL" SCRATCH="$ART/author" \
    "$AUTHOR" "$CLONE_DIR" "$AUTHOR_TAG" >"$RUN_LOG" 2>&1
  ARC=$?
  set -e
  END="$(date +%s)"
  WALL_S=$((END - START))
  cat "$RUN_LOG" >&2 || true
  [ "$ARC" -eq 0 ] || info "patch authoring did not apply (rc=$ARC) — git add -A below will find no change and exit without a PR."
else
  command -v opencode >/dev/null || die "opencode not in PATH (worker harness; see roles/agent-loop)."
  info "running harness: $OPENCODE_CMD -m $MODEL  (model=$MODEL)"
  START="$(date +%s)"
  # Prefer the JSON event stream so we can read token usage; fall back to default format.
  # `|| RC=$?` keeps a non-zero harness exit from killing us before we record wall time.
  RC=0
  if $OPENCODE_CMD -m "$MODEL" --format json "$TASK" >"$RUN_LOG" 2>&1; then :; else RC=$?; fi
  END="$(date +%s)"
  WALL_S=$((END - START))
  [ "$RC" -eq 0 ] || info "harness exited non-zero ($RC) — continuing to test/guard the working tree it left."

  # Best-effort token total from the JSON event stream (opencode emits usage objects). We
  # sum input+output across any usage-bearing events; if the format isn't JSON we get 0.
  TOKENS="$(RUN_LOG="$RUN_LOG" python3 <<'PY'
import json, os, re
total = 0
try:
    with open(os.environ["RUN_LOG"], "r", errors="replace") as f:
        data = f.read()
except OSError:
    data = ""
# opencode --format json emits one JSON object per line (events). Walk lines, find usage.
for line in data.splitlines():
    line = line.strip()
    if not line or line[0] not in "{[":
        continue
    try:
        obj = json.loads(line)
    except json.JSONDecodeError:
        continue
    def walk(o):
        global total
        if isinstance(o, dict):
            u = o.get("usage") or o.get("tokens")
            if isinstance(u, dict):
                for k in ("input", "output", "input_tokens", "output_tokens",
                          "prompt_tokens", "completion_tokens", "total", "total_tokens"):
                    v = u.get(k)
                    if isinstance(v, (int, float)):
                        total += int(v)
            for v in o.values():
                walk(v)
        elif isinstance(o, list):
            for v in o:
                walk(v)
    walk(obj)
print(total)
PY
)"
  [[ "$TOKENS" =~ ^[0-9]+$ ]] || TOKENS=0
fi

# --- did the harness produce a change? --------------------------------------------------
git add -A
if git diff --cached --quiet; then
  info "harness produced NO changes — nothing to commit. Exiting without a PR."
  emit --event run_exited --issue "$ISSUE" --detail "no-change"
  printf '{"issue":"%s","repo":"%s","branch":"%s","pr":null,"tests":"none","guard":"n/a","tokens":%s,"wall_s":%s,"head_sha":null}\n' \
    "$ISSUE" "$REPO" "$BRANCH" "$TOKENS" "$WALL_S"
  exit 0
fi

# --- GUARDRAIL: block delete-not-append BEFORE committing/pushing -----------------------
# Diff the staged change against base; a net drop in catalog/test entries exits the guard 2.
GUARD_VERDICT="ok"
set +e
git diff --cached "origin/$BASE" | "$GUARD" >"$ART/.worker-guard-${NUM}.json" 2>"$ART/.worker-guard-${NUM}.err"
GRC=$?
set -e
cat "$ART/.worker-guard-${NUM}.err" >&2 || true
if [ "$GRC" -eq 2 ]; then
  GUARD_VERDICT="blocked"
  info "GUARDRAIL BLOCKED the change (delete-not-append). NOT committing/pushing. Worker must re-author additively."
  emit --event run_exited --issue "$ISSUE" --detail "guard-blocked"
  printf '{"issue":"%s","repo":"%s","branch":"%s","pr":null,"tests":"not-run","guard":"blocked","tokens":%s,"wall_s":%s,"head_sha":null}\n' \
    "$ISSUE" "$REPO" "$BRANCH" "$TOKENS" "$WALL_S"
  exit 3
elif [ "$GRC" -ne 0 ]; then
  die "guardrail harness error (exit $GRC) — see the .err file."
fi

# --- commit ------------------------------------------------------------------------------
git commit --quiet -m "feat(${ISSUE}): worker change via ${HARNESS}/${MODEL}

Authored by the worker loop (PET-179). Additive change — guardrail-checked.
${ISSUE}"
HEAD_SHA="$(git rev-parse HEAD)"

# --- install + test (ground truth — host has local Postgres, PET-178) -------------------
TESTS=pass
TEST_LOG="$ART/.worker-test-${NUM}.log"
if [ "$DRY_RUN" = true ]; then
  info "[dry-run] skipping $INSTALL_CMD / $TEST_CMD."
  TESTS=skipped
else
  set +e
  eval "$INSTALL_CMD" >"$TEST_LOG" 2>&1; IRC=$?
  eval "$TEST_CMD" >>"$TEST_LOG" 2>&1; TRC=$?
  set -e
  { [ "$IRC" -eq 0 ] && [ "$TRC" -eq 0 ]; } || TESTS=fail
  info "tests: $TESTS (install rc=$IRC, test rc=$TRC)"
fi

# --- push (force-with-lease, OWN pet-* branch ONLY) -------------------------------------
PR_NUMBER="null"
PR_URL=""
if [ "$NO_PUSH" = true ] || [ "$DRY_RUN" = true ]; then
  info "skipping push/PR (${NO_PUSH:+--no-push }${DRY_RUN:+--dry-run})."
else
  # Re-assert the branch invariant at push time (never force-push a non-pet-* branch).
  [[ "$BRANCH" =~ ^pet-[0-9]+- ]] || die "push guard: '$BRANCH' is not a pet-<n>-* branch — refusing."
  git push --quiet --force-with-lease origin "HEAD:$BRANCH" ||
    die "push of $BRANCH failed (token push-scoped? branch protected?)."

  # Draft PR when tests fail (a red worker PR must not look mergeable); normal PR when green.
  PR_TITLE="${ISSUE}: $(printf '%s' "$SPEC" | head -1 | cut -c1-60)"
  PR_BODY_FILE="$ART/.worker-pr-body-${NUM}.md"
  # shellcheck disable=SC2016  # backticks in the format strings are markdown code spans, not shell.
  {
    printf '## Worker PR — %s\n\n' "$ISSUE"
    printf 'Authored by the **worker loop** (PET-179): `%s` via `%s`.\n\n' "$MODEL" "$HARNESS"
    printf -- '- **Independent `bun test`:** %s\n' "$TESTS"
    printf -- '- **Additive guardrail:** %s (no catalog/test entries dropped)\n' "$GUARD_VERDICT"
    printf -- '- **Head:** `%s`\n\n' "$HEAD_SHA"
    printf 'Mentions %s. The worker NEVER merges — Pedro/the reviewer decides.\n' "$ISSUE"
    printf '\n<sub>🤖 Worker loop on agent-worker (PET-179/PET-133). Draft = tests red.</sub>\n'
  } >"$PR_BODY_FILE"

  DRAFT_FLAG=()
  [ "$TESTS" = "fail" ] && DRAFT_FLAG=(--draft)
  # `gh pr create` is idempotent-ish: if a PR already exists for the branch it errors; we
  # then resolve the existing one instead of failing the run.
  if PR_URL="$(gh pr create --repo "$REPO" --base "$BASE" --head "$BRANCH" \
        --title "$PR_TITLE" --body-file "$PR_BODY_FILE" "${DRAFT_FLAG[@]}" 2>/dev/null)"; then
    :
  else
    PR_URL="$(gh pr view "$BRANCH" --repo "$REPO" --json url --jq .url 2>/dev/null || true)"
  fi
  if [ -n "$PR_URL" ]; then
    PR_NUMBER="$(gh pr view "$BRANCH" --repo "$REPO" --json number --jq .number 2>/dev/null || echo null)"
    info "PR: $PR_URL  (draft=$([ "$TESTS" = fail ] && echo yes || echo no))"
    emit --event pr_opened --issue "$ISSUE" --pr "$PR_NUMBER" --detail "tests=$TESTS"
  fi
fi

# --- append the worker eval-log row -----------------------------------------------------
# Mirrors the reviewer's verdict schema's worker-owned fields; written to a sibling JSONL
# (worker-runs.jsonl) so the reviewer's verdicts.jsonl stays the reviewer's. mc-on-MinIO,
# same append pattern; --dry-run just prints. Reuses agent-event's mc plumbing implicitly is
# NOT done — we keep a tiny inline python row and let the reviewer-log own MinIO writes.
LOG_DRY=""
{ [ "$DRY_RUN" = true ] || [ "$NO_PUSH" = true ]; } && LOG_DRY="(dry — not uploaded)"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ROW="$(
  TS="$TS" ISSUE="$ISSUE" REPO="$REPO" BRANCH="$BRANCH" PR="$PR_NUMBER" MODEL="$MODEL" \
  HARNESS="$HARNESS" TESTS="$TESTS" GUARD="$GUARD_VERDICT" TOKENS="$TOKENS" \
  WALL_S="$WALL_S" HEAD_SHA="${HEAD_SHA:-}" python3 <<'PY'
import json, os
row = {
    "ts": os.environ["TS"],
    "issue": os.environ["ISSUE"],
    "repo": os.environ["REPO"],
    "branch": os.environ["BRANCH"],
    "pr": (None if os.environ["PR"] in ("null", "") else int(os.environ["PR"])),
    "worker_model": os.environ["MODEL"],
    "harness": os.environ["HARNESS"],
    "tests": os.environ["TESTS"],
    "guard": os.environ["GUARD"],
    "tokens": int(os.environ["TOKENS"]),
    "wall_s": int(os.environ["WALL_S"]),
    "head_sha": os.environ["HEAD_SHA"],
}
print(json.dumps(row, separators=(",", ":"), ensure_ascii=False))
PY
)"
info "eval row $LOG_DRY: $ROW"
# Upload via mc only on a real run (same alias/bucket convention as reviewer-log-verdict.sh).
if [ "$DRY_RUN" = false ] && [ "$NO_PUSH" = false ] && command -v mc >/dev/null 2>&1; then
  ALIAS="${WORKER_MC_ALIAS:-homelab}"
  WPATH="${WORKER_RUNS_PATH:-agent-evals/worker-runs.jsonl}"
  TARGET="${ALIAS}/${WPATH}"
  if mc alias list "$ALIAS" >/dev/null 2>&1; then
    TMP="$ART/.worker-mc-${NUM}.tmp"   # in $ART so the single EXIT trap cleans it (no 2nd trap)
    if mc stat "$TARGET" >/dev/null 2>&1; then
      mc cat "$TARGET" >"$TMP" 2>/dev/null || true
      [ -s "$TMP" ] && [ "$(tail -c1 "$TMP")" != "" ] && printf '\n' >>"$TMP"
    fi
    printf '%s\n' "$ROW" >>"$TMP"
    if mc pipe "$TARGET" <"$TMP" >/dev/null 2>&1; then
      info "eval row appended to $TARGET"
    else
      info "eval-row upload skipped (mc/alias issue)."
    fi
  fi
fi

emit --event run_exited --issue "$ISSUE" --pr "$([ "$PR_NUMBER" = null ] && echo '' || echo "$PR_NUMBER")" --detail "tests=$TESTS guard=$GUARD_VERDICT"

# --- final JSON summary on stdout -------------------------------------------------------
printf '{"issue":"%s","repo":"%s","branch":"%s","pr":%s,"tests":"%s","guard":"%s","tokens":%s,"wall_s":%s,"head_sha":"%s"}\n' \
  "$ISSUE" "$REPO" "$BRANCH" "$PR_NUMBER" "$TESTS" "$GUARD_VERDICT" "$TOKENS" "$WALL_S" "${HEAD_SHA:-}"
