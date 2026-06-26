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
# KNOWN OVER-COUNT (catalog.added): the catalog-row regex matches an `id:`-opening line ANYWHERE
# in the diff, INCLUDING test files — so a worker's mirrored test that asserts on a multi-line
# object literal (e.g. `toMatchObject({ \n id: "the_star", \n kind: "tarot" })`) inflates
# catalog.added by 1 per such object. ONE new tarot can therefore report catalog.added=2 (the
# real entry + the test fixture). This does NOT affect the drop/block verdict (the identity-aware
# delete check is unaffected), but it makes catalog.added an UNRELIABLE "entries added" count.
# Consumers MUST NOT treat catalog.added as an exact entry count — worker-reconcile-asserts.sh
# uses it only as a loose UPPER bound (max(delta, CAP)) for its count-bump gate, never an
# equality. Left as-is on purpose: scoping the count to non-test files would touch the same
# pass that computes the block verdict, and the reconciler's verify-or-revert already neutralizes
# the noise. (242 end-to-end finding, PET-179.)
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

# Identity extractors: the VALUE that NAMES an entry. Comparing the SET of names removed vs
# re-added (not just counts) is what makes the guard robust:
#   * a removed-then-re-added line (pure reindent/reformat) is NOT a deletion (same id);
#   * a net-zero delete-AND-replace (drop greedy_joker+lusty_joker, add two new ids) IS
#     caught — counts net to 0 but the dropped ids are gone. (The old net<0 check missed it.)
cat_id_re = re.compile(r'''id\s*:\s*["']([^"']+)["']''')
test_name_re = re.compile(r'''(?:test|it|Deno\.test)(?:\.\w+)?\s*\(\s*["'`]([^"'`]+)''')

with open(sys.argv[1], "r", errors="replace") as _f:
    diff_lines = _f.read().splitlines()

tests_added = tests_removed = cat_added = cat_removed = 0
test_add, test_rem = set(), set()
cat_add, cat_rem = set(), set()
for line in diff_lines:
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
        m = test_name_re.search(body)
        if sign == "+":
            tests_added += 1
            if m: test_add.add(m.group(1))
        else:
            tests_removed += 1
            if m: test_rem.add(m.group(1))
    if catalog_re.search(body):
        m = cat_id_re.search(body)
        if sign == "+":
            cat_added += 1
            if m: cat_add.add(m.group(1))
        else:
            cat_removed += 1
            if m: cat_rem.add(m.group(1))

tests_net = tests_added - tests_removed
cat_net = cat_added - cat_removed
# Entries present on a removed line but NOT re-added = genuinely deleted (identity-aware).
deleted_catalog = sorted(cat_rem - cat_add)
deleted_tests = sorted(test_rem - test_add)
# Block on EITHER a NAMED deletion (catches net-zero delete-and-replace) OR a net drop
# (catches drops whose entries we couldn't name — multi-line / unquoted ids).
dropped = bool(deleted_catalog or deleted_tests or tests_net < 0 or cat_net < 0)

verdict = {
    "tests": {"added": tests_added, "removed": tests_removed, "net": tests_net,
              "deleted": deleted_tests},
    "catalog": {"added": cat_added, "removed": cat_removed, "net": cat_net,
                "deleted": deleted_catalog},
    "dropped": dropped,
    "allow_shrink": allow_shrink,
    "verdict": "shrink-allowed" if (dropped and allow_shrink)
               else ("blocked" if dropped else "ok"),
}
json.dump(verdict, sys.stdout, indent=2)
sys.stdout.write("\n")

def _why():
    bits = []
    if deleted_catalog:
        bits.append("catalog removed " + ", ".join(deleted_catalog))
    if deleted_tests:
        bits.append("tests removed " + ", ".join(deleted_tests))
    if not bits:
        bits.append(f"net tests {tests_net}, catalog {cat_net}")
    return "; ".join(bits)

if dropped and not allow_shrink:
    sys.stderr.write(
        "\033[1;31mGUARD BLOCKED: additive change REMOVED existing entries — "
        f"{_why()}. The worker likely overwrote-instead-of-appended (the 8B failure "
        "mode). Re-author additively or set WORKER_GUARD_ALLOW_SHRINK=1 for a genuine "
        "removal.\033[0m\n"
    )
    sys.exit(2)

if dropped and allow_shrink:
    sys.stderr.write(
        "\033[1;33mGUARD: entries removed but --allow-shrink set — "
        f"{_why()}. Allowed.\033[0m\n"
    )
else:
    sys.stderr.write(
        "\033[1;32mGUARD OK: no entries removed — "
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

  # Two synthetic diffs, both delete-not-append, both must BLOCK (exit 2). Quoted heredocs so
  # the diff bodies (which contain `(`/`)`/`[`) are never shell-parsed.
  ST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/worker-guard-selftest-XXXXXX")"
  trap 'rm -rf "$ST_DIR"' EXIT

  # Case net-drop: rewrote both files, dropped more than it added (3 catalog removed, 1 added;
  # 2 tests removed, 1 added) — net negative.
  cat >"$ST_DIR/net-drop.diff" <<'DIFF'
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

  # Case net-zero: removed 2 EXISTING jokers, added 2 NEW ones (catalog net 0). The old net<0
  # heuristic PASSED this; the identity check must still BLOCK (greedy_joker/lusty_joker gone).
  cat >"$ST_DIR/net-zero.diff" <<'DIFF'
--- a/src/engine/jokers.ts
+++ b/src/engine/jokers.ts
@@ -58,4 +58,4 @@ export const JOKERS = [
-  { id: "greedy_joker", name: "Greedy Joker", description: "+3 Mult per diamond" },
-  { id: "lusty_joker", name: "Lusty Joker", description: "+3 Mult per heart" },
+  { id: "icy_joker", name: "Icy Joker", description: "+9 Chips" },
+  { id: "fiery_joker", name: "Fiery Joker", description: "+9 Mult" },
DIFF

  st_fail=0
  for tc in net-drop net-zero; do
    set +e
    OUT="$(run_guard <"$ST_DIR/${tc}.diff")"; RC=$?
    set -e
    printf '\033[1m-- case %s (rc=%s) --\033[0m\n%s\n' "$tc" "$RC" "$OUT" >&2
    if [ "$RC" -ne 2 ]; then
      printf '\033[1;31mSELF-TEST FAIL: case %s expected exit 2 (blocked), got %s.\033[0m\n' "$tc" "$RC" >&2
      st_fail=1; continue
    fi
    # The identity check must NAME the dropped jokers in BOTH cases (net<0 and net==0).
    OUT="$OUT" TC="$tc" python3 - <<'CHECK' || st_fail=1
import json, os
v = json.loads(os.environ["OUT"]); tc = os.environ["TC"]
assert v["dropped"] is True, "expected dropped=true"
assert v["verdict"] == "blocked", "expected verdict=blocked, got " + str(v["verdict"])
assert {"greedy_joker", "lusty_joker"} <= set(v["catalog"]["deleted"]), \
    "expected greedy_joker+lusty_joker in catalog.deleted, got " + str(v["catalog"]["deleted"])
if tc == "net-zero":
    assert v["catalog"]["net"] == 0, "net-zero case should net 0, got " + str(v["catalog"]["net"])
CHECK
  done

  if [ "$st_fail" -eq 0 ]; then
    printf '\033[1;32mSELF-TEST PASS: both delete-not-append diffs caught (exit 2), incl. net-zero replace.\033[0m\n' >&2
    exit 0
  else
    die "SELF-TEST FAIL: see cases above — the guard did not catch a delete-not-append diff."
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
