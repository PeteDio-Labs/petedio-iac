#!/usr/bin/env bash
# reviewer-checkout-test.sh — run a worker PR's tests INDEPENDENTLY (ground truth).
#
# The REVIEWER half of the two-agent system (PET-135), step 2: never trust the worker's
# reported test result — re-run it ourselves. Clones the PR's repo into a throwaway temp
# dir, checks out the PR head, runs `bun install` + `bun test`, and prints a JSON summary
# (pass/fail + the tail of the output). The temp dir is always removed on exit.
#
# ISOLATED + READ-ONLY toward the remote: it clones fresh and checks out a detached PR
# head in /tmp, so it never touches the host's working clones and never pushes, commits,
# or comments. The verdict (the structured review) is Claude's job; this only produces
# the test ground-truth Claude cites.
#
# Usage:
#   scripts/reviewer/reviewer-checkout-test.sh <owner/repo> <pr-number>
#   e.g. scripts/reviewer/reviewer-checkout-test.sh PeteDio-Labs/co-latro-backend 42
#
# Env (optional):
#   REVIEWER_TEST_CMD     test command (default: "bun test")
#   REVIEWER_INSTALL_CMD  install command (default: "bun install")
#   REVIEWER_OUTPUT_TAIL  lines of output to keep in the JSON (default: 60)
#   REVIEWER_CLONE_DEPTH  shallow clone depth (default: 50)
#
# Output (stdout): one JSON object —
#   {"repo","pr","head_sha","installed","tests":"pass|fail","exit_code","output_tail"}
# The script's own exit code is 0 whenever it completed a test run (pass OR fail); a
# non-zero exit means the harness itself failed (clone/checkout/tooling), not a test
# failure — read "tests" for the result. `gh`/`git` use GH_TOKEN from the env; never printed.
set -euo pipefail

die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ $# -eq 2 ] || die "usage: $(basename "$0") <owner/repo> <pr-number>"
REPO="$1"
PR="$2"
[[ "$PR" =~ ^[0-9]+$ ]] || die "pr-number must be numeric (got '$PR')."

for t in gh git python3; do command -v "$t" >/dev/null || die "$t not in PATH."; done

INSTALL_CMD="${REVIEWER_INSTALL_CMD:-bun install}"
TEST_CMD="${REVIEWER_TEST_CMD:-bun test}"
TAIL_N="${REVIEWER_OUTPUT_TAIL:-60}"
DEPTH="${REVIEWER_CLONE_DEPTH:-50}"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/reviewer-${PR}-XXXXXX")"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

# Fresh shallow clone in /tmp — never the host's live clones. gh resolves auth from the env.
gh repo clone "$REPO" "$WORKDIR/repo" -- --depth "$DEPTH" --no-tags >/dev/null 2>&1 ||
  die "clone of $REPO failed (auth? repo exists?)."
cd "$WORKDIR/repo"

# Detached PR head — no local branch, nothing to accidentally push.
gh pr checkout "$PR" --detach >/dev/null 2>&1 ||
  die "checkout of PR #$PR failed (PR open? from a fork without head access?)."
HEAD_SHA="$(git rev-parse HEAD)"

LOG="$WORKDIR/run.log"
# `|| VAR=$?` captures the command's REAL exit code AND stops `set -e` from killing us on a
# test failure (a failing test is a result we report, not a harness error). Inside `if ! cmd`
# `$?` would be the negation's status (always 0), so we don't use that form here.
INSTALLED=true
INSTALL_RC=0
eval "$INSTALL_CMD" >"$LOG" 2>&1 || INSTALL_RC=$?
[ "$INSTALL_RC" -eq 0 ] || INSTALLED=false

TESTS=pass
EXIT_CODE=0
# Append the test output to the same log so the tail shows install + test context.
eval "$TEST_CMD" >>"$LOG" 2>&1 || EXIT_CODE=$?
[ "$EXIT_CODE" -eq 0 ] || TESTS=fail

# If install failed the test run is meaningless — surface it as a fail with the reason.
if [ "$INSTALLED" = false ]; then
  TESTS=fail
fi

REPO="$REPO" PR="$PR" HEAD_SHA="$HEAD_SHA" INSTALLED="$INSTALLED" \
TESTS="$TESTS" EXIT_CODE="$EXIT_CODE" TAIL_N="$TAIL_N" \
python3 - "$LOG" <<'PY'
import json, os, sys

log_path = sys.argv[1]
try:
    with open(log_path, "r", errors="replace") as f:
        lines = f.read().splitlines()
except OSError:
    lines = []

tail_n = int(os.environ["TAIL_N"])
tail = "\n".join(lines[-tail_n:])

json.dump({
    "repo": os.environ["REPO"],
    "pr": int(os.environ["PR"]),
    "head_sha": os.environ["HEAD_SHA"],
    "installed": os.environ["INSTALLED"] == "true",
    "tests": os.environ["TESTS"],
    "exit_code": int(os.environ["EXIT_CODE"]),
    "output_tail": tail,
}, sys.stdout, indent=2)
sys.stdout.write("\n")
PY
