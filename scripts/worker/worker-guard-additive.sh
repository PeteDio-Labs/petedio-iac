#!/usr/bin/env bash
# worker-guard-additive.sh — block the "green-but-wrong" delete-not-append fix (PET-179).
#
# The WORKER half of the two-agent system (PET-179), the guardrail. The 8B worker model's
# known failure mode (from the PET-133 spike) is OVERWRITE/DELETE-INSTEAD-OF-APPEND: asked
# to *add* a joker / voucher / test case, it rewrites the file and silently drops existing
# entries. The tests can still pass (fewer cases to satisfy), so a green `bun test` does NOT
# prove the change was additive. This guard is the deterministic check the test gate can't be:
# on an ADDITIVE issue, the net count of catalog entries and of test cases must NOT DROP.
#
# How it counts. It reads a unified diff (git diff / gh pr diff) and tallies, per hunk line:
#   * test cases  — added (`+`) vs removed (`-`) lines that OPEN a Bun/vitest case:
#                   `test(` / `it(` / `test.each(` / `it.each(` / `Deno.test(` …
#   * catalog rows — added vs removed lines that OPEN a catalog entry: an object literal
#                   keyed by `id:` (the Co-latro content shape — jokers.ts / vouchers.ts:
#                   `{ id: "greedy_joker", name: "…", … }`).
# It ignores `+++`/`---` file headers. NET = added − removed for each category. A NEGATIVE
# net (more removed than added) on an additive change is the red flag → non-zero exit.
#
# This is intentionally a HEURISTIC, count-based gate, not a semantic diff — cheap, language-
# agnostic enough for the two file shapes that matter, and biased toward FLAGGING (a false
# positive costs a human glance; a false negative ships a regression the worker's own green
# tests hid). Tune the openers via env if a repo's shape differs.
#
# Usage:
#   # from a file or stdin (a unified diff):
#   git diff main...HEAD | scripts/worker/worker-guard-additive.sh
#   scripts/worker/worker-guard-additive.sh path/to/change.diff
#   gh pr diff <n> | scripts/worker/worker-guard-additive.sh
#   # self-test (feeds a synthetic delete-not-append diff, asserts it is caught):
#   scripts/worker/worker-guard-additive.sh --self-test
#
# Env (optional):
#   WORKER_GUARD_TEST_RE      regex (python) matching a test-case opener on a stripped line
#                             (default: r'^\s*(test|it)(\.\w+)?\s*\(' plus Deno.test).
#   WORKER_GUARD_CATALOG_RE   regex matching a catalog-entry opener (default: an object that
#                             starts an `id:` field, e.g. r'^\s*\{?\s*id\s*:').
#   WORKER_GUARD_ALLOW_SHRINK set to 1 ONLY for a genuinely subtractive issue (a removal/
#                             refactor). Then a net drop is reported but exit stays 0.
#
# Exit: 0 when nothing drops (or --allow-shrink); 2 when a net drop is detected (the block);
# 1 on a usage/harness error. Prints a human summary on stderr and a JSON verdict on stdout.
set -euo pipefail

die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

SELF_TEST=false
DIFF_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --self-test) SELF_TEST=true; shift ;;
    -h | --help) sed -n '2,55p' "$0"; exit 0 ;;
    -*) die "unknown flag: $1 (see --help)" ;;
    *) DIFF_FILE="$1"; shift ;;
  esac
done

command -v python3 >/dev/null || die "python3 not in PATH (jq isn't on the loop host)."

# --- the counting core (shared by the real run and the self-test) -----------------------
# Reads a unified diff on its stdin, prints the JSON verdict on stdout, and exits 0/2 (or 1
# on a python error) so the caller's exit code IS the verdict. Kept as a function so the
# self-test can drive it with a synthetic diff without re-shelling.
run_guard() {
  # Stash stdin (the diff) into a temp file so the Python heredoc — which takes its OWN
  # stdin — still gets the diff, passed by path as argv[1]. (A heredoc-fed program can't
  # also read the function's stdin.)
  local _diff_tmp _rc
  _diff_tmp="$(mktemp "${TMPDIR:-/tmp}/worker-guard-in-XXXXXX")"
  cat >"$_diff_tmp"
  set +e
  WORKER_GUARD_TEST_RE="${WORKER_GUARD_TEST_RE:-}" \
  WORKER_GUARD_CATALOG_RE="${WORKER_GUARD_CATALOG_RE:-}" \
  WORKER_GUARD_ALLOW_SHRINK="${WORKER_GUARD_ALLOW_SHRINK:-0}" \
  python3 - "$_diff_tmp" <<'PY'
import json, os, re, sys

test_re = re.compile(os.environ.get("WORKER_GUARD_TEST_RE")
                     or r'^\s*(test|it)(\.\w+)?\s*\(|^\s*Deno\.test\s*\(')
catalog_re = re.compile(os.environ.get("WORKER_GUARD_CATALOG_RE")
                        or r'^\s*\{?\s*id\s*:')
allow_shrink = os.environ.get("WORKER_GUARD_ALLOW_SHRINK", "0") == "1"

with open(sys.argv[1], "r", errors="replace") as _f:
    diff_lines = _f.read().splitlines(keepends=True)

tests_added = tests_removed = cat_added = cat_removed = 0
for raw in diff_lines:
    line = raw.rstrip("\n")
    if not line:
        continue
    # Skip the unified-diff FILE headers (+++ / ---) — they aren't content lines.
    if line.startswith("+++") or line.startswith("---"):
        continue
    sign = line[0]
    if sign not in "+-":
        continue
    body = line[1:]               # the actual changed source line (strip the +/- marker)
    if test_re.search(body):
        if sign == "+":
            tests_added += 1
        else:
            tests_removed += 1
    if catalog_re.search(body):
        if sign == "+":
            cat_added += 1
        else:
            cat_removed += 1

tests_net = tests_added - tests_removed
cat_net = cat_added - cat_removed
# A DROP in either category is the delete-not-append signature.
dropped = (tests_net < 0) or (cat_net < 0)

verdict = {
    "tests": {"added": tests_added, "removed": tests_removed, "net": tests_net},
    "catalog": {"added": cat_added, "removed": cat_removed, "net": cat_net},
    "dropped": dropped,
    "allow_shrink": allow_shrink,
    "verdict": "shrink-allowed" if (dropped and allow_shrink)
               else ("blocked" if dropped else "ok"),
}
json.dump(verdict, sys.stdout, indent=2)
sys.stdout.write("\n")

if dropped and not allow_shrink:
    sys.stderr.write(
        "\033[1;31mGUARD BLOCKED: additive change DROPPED entries — "
        f"tests net {tests_net}, catalog net {cat_net}. "
        "The worker likely overwrote-instead-of-appended (the 8B failure mode). "
        "Re-author additively or set WORKER_GUARD_ALLOW_SHRINK=1 for a genuine removal.\033[0m\n"
    )
    sys.exit(2)

if dropped and allow_shrink:
    sys.stderr.write(
        "\033[1;33mGUARD: net drop present but --allow-shrink set — "
        f"tests net {tests_net}, catalog net {cat_net}. Allowed.\033[0m\n"
    )
else:
    sys.stderr.write(
        "\033[1;32mGUARD OK: no net drop — "
        f"tests net +{tests_net}, catalog net +{cat_net}.\033[0m\n"
    )
PY
  _rc=$?
  set -e
  rm -f "$_diff_tmp"
  return "$_rc"
}

# --- self-test: a synthetic delete-not-append diff MUST be caught ------------------------
if [ "$SELF_TEST" = true ]; then
  printf '\033[1mworker-guard self-test\033[0m: feeding a synthetic delete-not-append diff…\n' >&2

  # Synthetic diff: the worker was asked to ADD a joker + a test, but instead rewrote both
  # files and dropped MORE entries than it added (3 catalog rows removed, 1 added; 2 tests
  # removed, 1 added). The guard must BLOCK this (exit 2). Built into a temp file with a
  # quoted heredoc so the diff body (which contains `(`/`)`/`[`) is never shell-parsed.
  BAD_DIFF_FILE="$(mktemp "${TMPDIR:-/tmp}/worker-guard-selftest-XXXXXX.diff")"
  trap 'rm -f "$BAD_DIFF_FILE"' EXIT
  cat >"$BAD_DIFF_FILE" <<'DIFF'
--- a/src/engine/jokers.ts
+++ b/src/engine/jokers.ts
@@ -58,10 +58,4 @@ export const JOKERS = [
-  { id: "joker", name: "Joker", description: "+4 Mult" },
-  { id: "greedy_joker", name: "Greedy Joker", description: "+3 Mult per diamond" },
-  { id: "lusty_joker", name: "Lusty Joker", description: "+3 Mult per heart" },
+  { id: "shiny_new_joker", name: "Shiny New Joker", description: "+9 Mult" },
--- a/src/engine/jokers.test.ts
+++ b/src/engine/jokers.test.ts
@@ -10,8 +10,4 @@ describe("jokers", () => {
-  test("joker adds +4 mult", () => {});
-  it("greedy joker scores diamonds", () => {});
+  test("shiny new joker adds +9 mult", () => {});
DIFF

  # We expect exit 2 (blocked). Capture stdout (the JSON) and the exit code WITHOUT letting
  # `set -e` abort on the intended non-zero.
  set +e
  OUT="$(run_guard <"$BAD_DIFF_FILE")"
  RC=$?
  set -e
  printf '%s\n' "$OUT"

  if [ "$RC" -eq 2 ]; then
    # Confirm the JSON also says blocked with negative nets — belt and suspenders.
    OUT="$OUT" python3 - <<'CHECK' || die "self-test: verdict JSON did not confirm a block."
import json, os
v = json.loads(os.environ["OUT"])
assert v["dropped"] is True, "expected dropped=true"
assert v["verdict"] == "blocked", "expected verdict=blocked, got " + str(v["verdict"])
assert v["catalog"]["net"] < 0, "expected catalog net < 0"
assert v["tests"]["net"] < 0, "expected tests net < 0"
CHECK
    printf '\033[1;32mSELF-TEST PASS: delete-not-append diff was caught (exit 2, verdict=blocked).\033[0m\n' >&2
    exit 0
  else
    die "SELF-TEST FAIL: expected exit 2 (blocked), got $RC. The guard did NOT catch the delete-not-append diff."
  fi
fi

# --- real run: read the diff from a file arg or stdin -----------------------------------
if [ -n "$DIFF_FILE" ]; then
  [ -f "$DIFF_FILE" ] || die "diff file not found: $DIFF_FILE"
  run_guard <"$DIFF_FILE"
else
  # No file → expect a diff piped on stdin. A bare TTY with nothing piped is a usage error.
  [ -t 0 ] && die "no diff given: pipe a unified diff or pass a file (see --help)."
  run_guard
fi
