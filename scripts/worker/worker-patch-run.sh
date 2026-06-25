#!/usr/bin/env bash
# worker-patch-run.sh — standalone TEST HARNESS for the constrained patch-apply worker
# (PET-173 / PET-133 / PET-182). Clones the target repo, calls the shared authoring core
# (worker-patch-author.sh) to make the additive change, then gates it with the additive guard
# + `bun test` on the touched test file. NO push/PR (that is worker-run.sh's job).
#
# The authoring mechanics live in worker-patch-author.sh (ONE implementation, shared with the
# production loop). This wrapper is the bake-off / smoke harness around it.
#
# Usage:  worker-patch-run.sh <ollama-model-tag>     e.g. worker-patch-run.sh qwen2.5-coder:7b
# Env:    OLLAMA_URL (default http://192.168.50.12:11434), REPO (default PeteDio-Labs/co-latro-backend),
#         SPEC_FILE (path to the task spec; defaults to a built-in voucher example),
#         GUARD (path to worker-guard-additive.sh), WORKDIR, KEEP=1 (keep workdir),
#         CATALOG_FILE/NEW_ID/SIBLING_ID (forwarded to the author for thin specs).
# Output: per-model JSON on stdout: {"model","diff_applied","apply_method","guard","tests",
#         "catalog_file","test_file","new_id","sibling_id","notes"}. Exit 0 always (JSON carries
#         the verdict); exit 1 only on a harness/usage error.
set -uo pipefail

MODEL="${1:?usage: worker-patch-run.sh <ollama-model-tag>}"
OLLAMA_URL="${OLLAMA_URL:-http://192.168.50.12:11434}"
REPO="${REPO:-PeteDio-Labs/co-latro-backend}"
KEEP="${KEEP:-0}"
err() { printf '[harness] %s\n' "$*" >&2; }
WORKDIR="${WORKDIR:-$(mktemp -d "${TMPDIR:-/tmp}/worker-patch-XXXXXX")}"
CLONE="$WORKDIR/repo"
NOTES=""
add_note() { NOTES="${NOTES:+$NOTES; }$1"; err "$1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTHOR="$SCRIPT_DIR/worker-patch-author.sh"

# Verdict fields surfaced from the author + this wrapper's guard/test.
CATALOG_REL=""; TEST_REL=""; NEW_ID=""; SIBLING_ID=""
emit() {  # $1 diff_applied(bool) $2 apply_method $3 guard $4 tests
  python3 - "$MODEL" "$1" "$2" "$3" "$4" "$NOTES" "$CATALOG_REL" "$TEST_REL" "$NEW_ID" "$SIBLING_ID" <<'PY'
import json, sys
m, applied, method, guard, tests, notes, cat, test, nid, sib = sys.argv[1:11]
print(json.dumps({"model": m, "diff_applied": applied == "true", "apply_method": method,
                  "guard": guard, "tests": tests, "catalog_file": cat, "test_file": test,
                  "new_id": nid, "sibling_id": sib, "notes": notes}))
PY
  [ "$KEEP" = "1" ] || rm -rf "$WORKDIR"
  exit 0
}

[ -x "$AUTHOR" ] || { add_note "authoring core not found/executable: $AUTHOR"; emit false none error none; }

# (1) fresh clone + checkout main
err "cloning $REPO -> $CLONE"
gh repo clone "$REPO" "$CLONE" -- --depth 1 >/dev/null 2>&1 || { add_note "clone failed"; emit false none error none; }
git -C "$CLONE" checkout main >/dev/null 2>&1 || git -C "$CLONE" checkout -B main >/dev/null 2>&1

# Default spec (voucher example) if the caller didn't pass one.
SPEC_FILE="${SPEC_FILE:-}"
if [ -z "$SPEC_FILE" ] || [ ! -f "$SPEC_FILE" ]; then
  SPEC_FILE="$WORKDIR/default-spec.txt"
  cat >"$SPEC_FILE" <<'SPEC'
Append a "fortune_scale" voucher to src/engine/vouchers.ts (tier-1, NO requires field),
copying the shape of the existing seed_money entry, and add a test to vouchers.test.ts
mirroring the seed_money test (assert effectiveInterestCap rises by 5).
SPEC
fi

# Locate the guard (forwarded only to this wrapper's gate, not the author).
GUARD="${GUARD:-}"
if [ -z "$GUARD" ]; then
  for cand in "$SCRIPT_DIR/worker-guard-additive.sh" \
              "/home/agent/work/petedio/iac/scripts/worker/worker-guard-additive.sh"; do
    [ -f "$cand" ] && { GUARD="$cand"; break; }
  done
fi

# (2) AUTHOR — the shared constrained patch-apply core mutates the clone in place.
AUTHOR_JSON="$(SPEC_FILE="$SPEC_FILE" OLLAMA_URL="$OLLAMA_URL" SCRATCH="$WORKDIR/author" \
  "$AUTHOR" "$CLONE" "$MODEL" 2>>"$WORKDIR/author.err")"
AUTH_RC=$?
# Surface the author's resolved targets + notes into our verdict.
eval "$(python3 - "$AUTHOR_JSON" <<'PY'
import json, sys, shlex
try:
    d = json.loads(sys.argv[1])
except Exception:
    d = {}
for k, var in (("catalog_file","CATALOG_REL"),("test_file","TEST_REL"),
               ("new_id","NEW_ID"),("sibling_id","SIBLING_ID"),
               ("apply_method","APPLY_METHOD"),("notes","AUTHOR_NOTES")):
    print(f"{var}={shlex.quote(str(d.get(k) or ''))}")
print(f"AUTHOR_APPLIED={shlex.quote('true' if d.get('applied') else 'false')}")
PY
)"
[ -n "${AUTHOR_NOTES:-}" ] && add_note "author: $AUTHOR_NOTES"
if [ "${AUTHOR_APPLIED:-false}" != "true" ]; then
  add_note "authoring did not apply (rc=$AUTH_RC)"; emit false "${APPLY_METHOD:-none}" none none
fi

# (3) guard, then bun install + bun test on the touched test file
APPLIED_DIFF="$WORKDIR/applied.diff"; git -C "$CLONE" diff >"$APPLIED_DIFF"
GUARD_RESULT="skipped"
if [ -n "$GUARD" ] && [ -f "$GUARD" ]; then
  bash "$GUARD" "$APPLIED_DIFF" >"$WORKDIR/guard.out" 2>"$WORKDIR/guard.err"; GRC=$?
  if [ "$GRC" -eq 0 ]; then GUARD_RESULT="ok"; elif [ "$GRC" -eq 2 ]; then GUARD_RESULT="blocked"; else GUARD_RESULT="error"; fi
  add_note "guard exit $GRC ($GUARD_RESULT)"
else add_note "guard script not found; skipped"; fi

TESTS="none"; err "bun install + bun test $TEST_REL ..."
if (cd "$CLONE" && bun install >/dev/null 2>&1); then
  (cd "$CLONE" && bun test "$TEST_REL") >"$WORKDIR/test.out" 2>&1; TRC=$?
  PASS="$(grep -Eo '[0-9]+ pass' "$WORKDIR/test.out" | tail -1)"
  FAILN="$(grep -Eo '[0-9]+ fail' "$WORKDIR/test.out" | tail -1)"
  HASNEW="$(grep -c "$NEW_ID" "$WORKDIR/test.out" 2>/dev/null || true)"
  [ "$TRC" -eq 0 ] && TESTS="pass" || TESTS="fail"
  add_note "tests($TEST_REL): ${PASS:-?}, ${FAILN:-?} (rc=$TRC); new-id refs in output=$HASNEW"
else add_note "bun install failed"; TESTS="none"; fi
emit true "${APPLY_METHOD:-unknown}" "$GUARD_RESULT" "$TESTS"
