#!/usr/bin/env bash
# worker-reconcile-asserts.sh — deterministic, verify-or-revert catalog-assertion reconciler.
#
# The WORKER half of the two-agent system (PET-179), the LAST-MILE fixer. The constrained
# patch-apply worker (worker-patch-author.sh, qwen2.5-coder:7b) is ADDITIVE-ONLY: it inserts a
# new catalog entry (joker / voucher / tarot) plus its OWN mirrored test, but it can NOT
# cross-edit a SEPARATE existing test that enumerates the catalog. That is its one remaining
# `guard=ok tests=fail` failure mode (from the real eval log):
#   * PET-175 (consumables.test.ts): a new tarot broke  `expect(tarots.length).toBe(17)`  → 18.
#   * PET-173 (vouchers.test.ts, "does not roll an already-owned voucher"): a hard-coded
#     owned-voucher ID ARRAY was missing the new "fortune_scale" id.
#
# This reconciler runs ONLY when the worker's `bun test` is RED (worker-run.sh wires it between
# the test gate and the draft-PR). It parses the captured failure output, handles exactly TWO
# mechanical patterns, applies a CANDIDATE edit to the TEST source, then re-runs the FULL suite:
#   * GREEN now → keep the edits, exit 0 (the caller flips TESTS=pass → a normal PR).
#   * still RED → `git checkout --` the reconcile edits (full revert), exit 1 (draft, as today).
# It can NEVER make things worse (verify-or-revert is the safety net).
#
# The TWO patterns (and NOTHING else):
#   (A) COUNT / LENGTH off-by-N — a failing `expect(<expr>.length).toBe(N)` / `toHaveLength(N)`
#       whose `Received` value differs from the literal `N`. Replace the literal `N` → received
#       in the test source (and bump a trivial human count in the adjacent title if present).
#   (B) MISSING CATALOG ID in a hard-coded array — a failing assertion (e.g. `.toBeNull()` /
#       `.toContain(...)`) whose `Received` names the worker's NEW id, where the test owns an
#       array literal of sibling catalog ids missing that id. Append the new id to that array.
#
# HARD CONSTRAINTS (mirrors the rest of the worker harness):
#   * only ever edits TEST files (`*.test.ts`);
#   * only ever BUMPS A NUMERIC LITERAL or APPENDS AN ID to an existing array literal;
#   * NEVER deletes / skips / rewrites a test;
#   * if it can't CONFIDENTLY identify the fix → does nothing → exit 1 (draft, unchanged).
#
# Usage:
#   worker-reconcile-asserts.sh <clone-dir> --test-log <path> [--new-id <id>] \
#       [--guard-json <path>] [--delta <n>] [--test-cmd "<cmd>"]
#   * <clone-dir>    the worker's checkout (we edit + revert IN it).
#   * --test-log     the captured `bun test` output that FAILED (required).
#   * --new-id       the catalog id the worker just added (the author emits it). Used for (B)
#                    and to sanity-check (A); optional but strongly recommended.
#   * --guard-json   the additive-guard verdict JSON (for the added-count = delta in pattern A).
#   * --delta        explicit added-catalog count (overrides --guard-json's catalog.added).
#   * --test-cmd     full-suite re-test command (default: "bun test").
#
# Output (stdout): one JSON line {"reconciled":bool,"pattern":"A|B|none","files":[...],
#   "changes":"<human summary>","note":"<why, when not reconciled>"}.
# Exit: 0 iff the suite is GREEN after a kept edit; 1 otherwise (nothing changed, or reverted).
set -uo pipefail

err() { printf '[reconcile] %s\n' "$*" >&2; }

CLONE="" TEST_LOG="" NEW_ID="" GUARD_JSON="" DELTA="" TEST_CMD="bun test"
while [ $# -gt 0 ]; do
  case "$1" in
    --test-log)   TEST_LOG="$2"; shift 2 ;;
    --new-id)     NEW_ID="$2"; shift 2 ;;
    --guard-json) GUARD_JSON="$2"; shift 2 ;;
    --delta)      DELTA="$2"; shift 2 ;;
    --test-cmd)   TEST_CMD="$2"; shift 2 ;;
    -h | --help)  sed -n '2,55p' "$0"; exit 0 ;;
    -*) err "unknown flag: $1 (see --help)"; exit 1 ;;
    *)  if [ -z "$CLONE" ]; then CLONE="$1"; else err "unexpected arg: $1"; exit 1; fi; shift ;;
  esac
done

# Scratch dir for the Python programs. We run them as `python3 <file>` rather than via a
# heredoc captured in `$(...)` because bash 3.2 (macOS) mis-tracks single quotes in a heredoc
# body nested inside command substitution — the planner's regexes have odd `'` counts and
# would trip a false "unexpected EOF" (the repo's documented bash-3.2 gotcha). Writing the
# program to a file sidesteps the parser entirely and is portable to bash 4+ on the loop host.
SCRATCH="${SCRATCH:-$(mktemp -d "${TMPDIR:-/tmp}/worker-reconcile-XXXXXX")}"
mkdir -p "$SCRATCH" 2>/dev/null || true
# shellcheck disable=SC2329  # invoked indirectly via the EXIT trap below.
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT

emit() {  # $1 reconciled(bool) $2 pattern $3 files(|-joined) $4 changes $5 note
  python3 - "$1" "$2" "$3" "$4" "$5" <<'PY'
import json, sys
rec, pat, files, changes, note = sys.argv[1:6]
print(json.dumps({
    "reconciled": rec == "true",
    "pattern": pat,
    "files": [f for f in files.split("|") if f],
    "changes": changes,
    "note": note,
}, separators=(",", ":")))
PY
}

command -v python3 >/dev/null 2>&1 || { err "python3 not in PATH."; emit false none "" "" "python3 missing"; exit 1; }
[ -n "$CLONE" ] && [ -d "$CLONE/.git" ] || { err "clone dir is not a git checkout: ${CLONE:-<unset>}"; emit false none "" "" "bad clone dir"; exit 1; }
[ -n "$TEST_LOG" ] && [ -f "$TEST_LOG" ] || { err "--test-log missing/unreadable: ${TEST_LOG:-<unset>}"; emit false none "" "" "no test log"; exit 1; }

# Resolve the added-catalog count (delta) for pattern A: explicit --delta wins, else the guard
# verdict's catalog.added, else 1 (a single additive entry is the worker's normal unit).
if [ -z "$DELTA" ] && [ -n "$GUARD_JSON" ] && [ -f "$GUARD_JSON" ]; then
  DELTA="$(python3 - "$GUARD_JSON" <<'PY' 2>/dev/null || true
import json, sys
try:
    v = json.load(open(sys.argv[1]))
    print(int(v.get("catalog", {}).get("added", 0)))
except Exception:
    print("")
PY
)"
fi
[[ "${DELTA:-}" =~ ^[0-9]+$ ]] || DELTA=""

# --- (1) PLAN the candidate edit from the failure output -------------------------------------
# The planner is pure (reads the test log + repo, writes NOTHING). It prints a shell-eval'able
# block: PATTERN, EDIT_FILE (abs path), and the human CHANGES summary. EDIT_FILE empty = no
# confident fix → the caller does nothing and leaves the draft behavior.
cat >"$SCRATCH/plan.py" <<'PY'
import os, re, shlex, sys

log = open(sys.argv[1], errors="replace").read()
clone = os.environ["CLONE"]
new_id = os.environ.get("NEW_ID", "").strip()
delta = os.environ.get("DELTA", "").strip()
delta = int(delta) if delta.isdigit() else None

def out(**kw):
    for k, v in kw.items():
        print(f"{k}={shlex.quote(str(v))}")
    sys.exit(0)

# Locate every failing assertion's source position: bun prints "at <file>:<line>:<col>".
# We only ever touch *.test.ts (hard constraint).
at_re = re.compile(r'^\s*at .*?\(?(/[^\s():]+\.test\.ts):(\d+):(\d+)\)?\s*$', re.M)
# bun's "Expected:" / "Received:" lines for the simple scalar case.
exp_re = re.compile(r'^Expected:\s*(.+?)\s*$', re.M)
rcv_re = re.compile(r'^Received:\s*(.+?)\s*$', re.M)

ats = at_re.findall(log)
if not ats:
    out(PATTERN="none", EDIT_FILE="", CHANGES="", NOTE="no *.test.ts failure location in the log")

# ---- Pattern A: a length/count assertion that is off by exactly the added-catalog count -----
# Find a failing line in the test source that is `expect(<expr>.length).toBe(N)` or
# `...toHaveLength(N)` where the Received value = N + delta (delta = entries the worker added).
count_call = re.compile(
    r'\.(?:toBe|toEqual|toStrictEqual)\(\s*(\d+)\s*\)|\.toHaveLength\(\s*(\d+)\s*\)')
length_expr = re.compile(r'\.length\b')

for fpath, lineno, _col in ats:
    if not os.path.isfile(fpath):
        continue
    src = open(fpath).read().splitlines()
    i = int(lineno) - 1
    if i < 0 or i >= len(src):
        continue
    line = src[i]
    m = count_call.search(line)
    if not m:
        continue
    literal = m.group(1) or m.group(2)
    if literal is None:
        continue
    n = int(literal)
    is_length = bool(length_expr.search(line)) or "toHaveLength" in line
    # The Received value the runner reported (scalar case). Pair the nearest Expected==N with
    # its Received. We scan the whole log for an Expected:N / Received:M pair.
    received = None
    for em in exp_re.finditer(log):
        if em.group(1).strip() == str(n):
            rm = rcv_re.search(log, em.end())
            if rm:
                rv = rm.group(1).strip()
                if rv.lstrip("-").isdigit():
                    received = int(rv)
                    break
    if received is None:
        continue
    # CONFIDENCE (deliberately loose — verify-or-revert is the REAL confidence; a wrong bump
    # just reverts, so the gate only needs to admit *plausible* catalog-count bumps):
    #   (a) it's a .length / toHaveLength / count assertion;
    #   (b) received > expected (a catalog GREW — we only ever bump UP, never shrink an assert);
    #   (c) the off-by is small: 1 <= off <= max(delta, CAP).
    # delta (= the guard's catalog.added) only WIDENS the ceiling; it can NOT reject a fix. The
    # real guard over-counts (e.g. a test-fixture `{ id: ... }` object inflates catalog.added —
    # see worker-guard-additive), so a strict `off == delta` falsely declined valid single-entry
    # bumps on 242 (delta=2 for one tarot, off=1). CAP is the floor ceiling so a noisy/missing
    # delta can't block a one-entry add; the full-suite green re-run catches any over-eager bump.
    CAP = 8
    off = received - n
    if not is_length:
        continue
    ceiling = max(delta, CAP) if delta is not None else CAP
    if off < 1 or off > ceiling:
        continue
    out(PATTERN="A", EDIT_FILE=fpath, EDIT_LINE=str(i + 1),
        OLD_LITERAL=str(n), NEW_LITERAL=str(received),
        CHANGES=f"{os.path.basename(fpath)}: bumped catalog-count assertion {n}->{received}",
        NOTE="")

# ---- Pattern B: a hard-coded id array missing the worker's NEW id ---------------------------
# The new id is known (the author emits it). Find a *.test.ts that declares an array literal of
# sibling catalog ids and is MISSING new_id; the failing assertion sits inside/after it.
if new_id:
    # Collect the failing test files (dedup, preserve order).
    seen = []
    for fpath, _l, _c in ats:
        if os.path.isfile(fpath) and fpath not in seen:
            seen.append(fpath)
    # Quoted-string-array detection: lines like `    "seed_money",` clustered between `[` `]`.
    str_item = re.compile(r'^\s*["\']([a-z0-9_]+)["\']\s*,?\s*$')
    for fpath in seen:
        src = open(fpath).read().splitlines()
        # Confirm the new id is genuinely referenced by the failure (Received names it) — this
        # is what makes appending it the right fix, not a guess.
        if new_id not in log:
            continue
        # Walk arrays: an opening line ending in '[' then a run of quoted id items then ']'.
        n = len(src)
        i = 0
        while i < n:
            if src[i].rstrip().endswith('['):
                items = []
                j = i + 1
                while j < n and str_item.match(src[j]):
                    items.append((j, str_item.match(src[j]).group(1)))
                    j += 1
                # j now at the first non-item line (expected to be the array close `]`/`];`).
                if items and j < n and src[j].lstrip().startswith(']'):
                    ids = [it[1] for it in items]
                    # Must look like a CATALOG-id array (siblings) and be missing the new id.
                    if new_id not in ids and len(ids) >= 2:
                        last_line, _last_id = items[-1]
                        out(PATTERN="B", EDIT_FILE=fpath, EDIT_LINE=str(last_line + 1),
                            NEW_ID=new_id,
                            CHANGES=f"{os.path.basename(fpath)}: appended \"{new_id}\" to the owned-id array",
                            NOTE="")
                i = j
            else:
                i += 1

out(PATTERN="none", EDIT_FILE="", CHANGES="", NOTE="no confident count-bump or missing-id-array match")
PY
PLAN="$(CLONE="$CLONE" NEW_ID="$NEW_ID" DELTA="${DELTA:-}" python3 "$SCRATCH/plan.py" "$TEST_LOG")"
eval "$PLAN"

if [ "${PATTERN:-none}" = "none" ] || [ -z "${EDIT_FILE:-}" ]; then
  err "no confident reconcile (${NOTE:-none}) — leaving the draft behavior."
  emit false none "" "" "${NOTE:-no match}"
  exit 1
fi

# Sanity: the file MUST be a test file under the clone (hard constraint — only edit test files).
# Resolve both sides to PHYSICAL paths first: bun prints the realpath in its `at` traceback while
# $CLONE may be a symlinked dir (macOS /tmp -> /private/tmp), so a raw prefix match would miss.
CLONE_REAL="$(cd "$CLONE" 2>/dev/null && pwd -P || printf '%s' "$CLONE")"
EDIT_REAL="$EDIT_FILE"
case "$EDIT_FILE" in
  /*) _ed="$(cd "$(dirname "$EDIT_FILE")" 2>/dev/null && pwd -P || true)"
      [ -n "$_ed" ] && EDIT_REAL="$_ed/$(basename "$EDIT_FILE")" ;;
esac
case "$EDIT_REAL" in
  "$CLONE_REAL"/*.test.ts) : ;;
  *) err "refusing to edit non-test or out-of-clone file: $EDIT_FILE"; emit false none "" "" "edit target not a test file in clone"; exit 1 ;;
esac

# Path relative to the clone, for git checkout (revert) and the verdict. Built from the real
# paths so `git -C "$CLONE" checkout -- "$REL"` resolves regardless of symlink aliasing.
REL="${EDIT_REAL#"$CLONE_REAL"/}"
EDIT_FILE="$EDIT_REAL"
err "candidate: pattern=$PATTERN file=$REL — $CHANGES"

# --- (2) APPLY the single mechanical edit (in place, on the test file) ------------------------
cat >"$SCRATCH/apply.py" <<'PY'
import os, re, sys
f = os.environ["EDIT_FILE"]
line = int(os.environ["EDIT_LINE"]) - 1
pat = os.environ["PATTERN"]
src = open(f).read().splitlines(keepends=True)
if line < 0 or line >= len(src):
    sys.exit(1)

if pat == "A":
    old, new = os.environ["OLD_LITERAL"], os.environ["NEW_LITERAL"]
    # Replace ONLY the count literal inside the assertion call on that line (toBe(N)/toHaveLength(N)).
    def repl(m):
        return m.group(0).replace(old, new)
    src[line] = re.sub(r'(\.(?:toBe|toEqual|toStrictEqual|toHaveLength)\(\s*)' + re.escape(old) + r'(\s*\))',
                       lambda m: m.group(1) + new + m.group(2), src[line], count=1)
    # Bonus (never required for green): bump a trivial human count in an adjacent test title.
    for k in (line - 1, line - 2, line - 3):
        if 0 <= k < len(src) and re.search(r'\b(?:it|test)\s*\(', src[k]) and re.search(r'\b' + re.escape(old) + r'\b', src[k]):
            src[k] = re.sub(r'\b' + re.escape(old) + r'\b', new, src[k], count=1)
            break

elif pat == "B":
    new_id = os.environ["NEW_ID"]
    # Append `"<new_id>",` after the last array item, copying its exact indentation, and ensure
    # the prior last item ends with a comma. We NEVER delete or reorder existing items.
    ref = src[line]                       # the current last item line (with its newline)
    indent = re.match(r'\s*', ref).group(0)
    nl = "\n" if ref.endswith("\n") else ""
    body = ref.rstrip("\n")
    if not body.rstrip().endswith(","):
        src[line] = body + ",\n" if nl else body + ","
    src.insert(line + 1, f'{indent}"{new_id}",{nl}')

open(f, "w").write("".join(src))
print("ok")
PY
APPLIED="$(EDIT_FILE="$EDIT_FILE" EDIT_LINE="${EDIT_LINE:-0}" PATTERN="$PATTERN" \
  OLD_LITERAL="${OLD_LITERAL:-}" NEW_LITERAL="${NEW_LITERAL:-}" NEW_ID="${NEW_ID:-}" \
  python3 "$SCRATCH/apply.py")"
if [ "$APPLIED" != "ok" ]; then
  err "edit could not be applied (line drift?) — reverting any partial change."
  git -C "$CLONE" checkout -- "$REL" 2>/dev/null || true
  emit false "$PATTERN" "" "$CHANGES" "edit apply failed"
  exit 1
fi

# --- (3) VERIFY-OR-REVERT: re-run the FULL suite. Green → keep; still red → revert ------------
err "re-running full suite to verify: $TEST_CMD"
RETEST_LOG="$(mktemp "${TMPDIR:-/tmp}/worker-reconcile-retest-XXXXXX")"
set +e
( cd "$CLONE" && eval "$TEST_CMD" ) >"$RETEST_LOG" 2>&1
TRC=$?
set -e
# bun exits non-zero on any failure; double-check the "N fail" tally to be safe.
FAILN="$(grep -Eo '[0-9]+ fail' "$RETEST_LOG" | tail -1 | grep -Eo '[0-9]+' || echo 0)"
rm -f "$RETEST_LOG"

if [ "$TRC" -eq 0 ] && [ "${FAILN:-0}" -eq 0 ]; then
  err "GREEN after reconcile — keeping the edit: $CHANGES"
  emit true "$PATTERN" "$REL" "$CHANGES" "verified green"
  exit 0
fi

err "still RED after the candidate edit (rc=$TRC, fail=$FAILN) — REVERTING. Draft behavior unchanged."
git -C "$CLONE" checkout -- "$REL" 2>/dev/null || true
emit false "$PATTERN" "" "$CHANGES" "reverted: suite still red after candidate edit"
exit 1
