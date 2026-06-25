#!/usr/bin/env bash
# worker-patch-run.sh — GENERALIZED constrained single-shot patch-apply worker harness
# (PET-173 / PET-133). Generalizes scripts/worker/worker-patch-apply.sh from VOUCHERS-only to
# ANY Co-latro content add: jokers (src/engine/jokers.ts), vouchers (src/engine/vouchers.ts),
# consumables (src/engine/consumables.ts: tarots/spectrals/planets).
#
# Proven mechanics are UNCHANGED:
#   * ONE constrained model call (add-only unified diff, qwen2.5-coder:7b, /api/chat, temp 0,
#     num_ctx 8192) — small models botch hunk geometry, so we
#   * take ONLY the model's "+" lines per file, then
#   * deterministic ANCHOR-INSERT (git apply tried first, anchor-insert is the reliable path),
#   * gate with the additive guard + `bun test` on the touched test file.
#
# What is GENERALIZED (see anchor_logic in the task return):
#   1. Target CATALOG file/array — discovered from the spec (which names the file, e.g.
#      src/engine/jokers.ts) AND the sibling entry's id. We insert before the closing "];" of
#      the array the SIBLING lives in (NOT the file's last "];" blindly — consumables/jokers
#      can hold helper arrays/Maps after the catalog).
#   2. Target TEST file — sibling catalog file foo.ts -> foo.test.ts.
#   3. Target DESCRIBE — found generically by locating the SIBLING test (anchor on the spec's
#      sibling id, which appears in the test body, e.g. run.vouchers.push("seed_money") /
#      getJoker("gluttonous_joker") / useConsumable(... "medium")) and walking up to its
#      enclosing describe(...) — NO hardcoded "effective caps".
#
# Usage:  worker-patch-run.sh <ollama-model-tag>     e.g. worker-patch-run.sh qwen2.5-coder:7b
# Env:    OLLAMA_URL (default http://192.168.50.12:11434), REPO (default PeteDio-Labs/co-latro-backend),
#         SPEC_FILE (required for non-voucher targets), GUARD (path to worker-guard-additive.sh),
#         WORKDIR, KEEP=1 (keep workdir / no cleanup — there is no push in this harness).
#         NEW_ID / SIBLING_ID / CATALOG_FILE — optional explicit overrides if spec parsing is thin.
# Output: per-model JSON on stdout: {"model","diff_applied","apply_method","guard","tests",
#         "catalog_file","test_file","new_id","sibling_id","notes"}.
#         Exit 0 always (JSON carries the verdict); exit 1 only on a harness/usage error.
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

# Filled in once we parse the spec; emitted in the JSON verdict.
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

# (1) fresh clone + checkout main
err "cloning $REPO -> $CLONE"
gh repo clone "$REPO" "$CLONE" -- --depth 1 >/dev/null 2>&1 || { add_note "clone failed"; emit false none error none; }
git -C "$CLONE" checkout main >/dev/null 2>&1 || git -C "$CLONE" checkout -B main >/dev/null 2>&1

GUARD="${GUARD:-}"
if [ -z "$GUARD" ]; then
  for cand in "$(dirname "$0")/worker-guard-additive.sh" \
              "/home/agent/work/petedio/iac/scripts/worker/worker-guard-additive.sh"; do
    [ -f "$cand" ] && { GUARD="$cand"; break; }
  done
fi

# (2) read spec
SPEC_FILE="${SPEC_FILE:-}"
if [ -n "$SPEC_FILE" ] && [ -f "$SPEC_FILE" ]; then
  SPEC="$(cat "$SPEC_FILE")"
else
  SPEC='Append a "fortune_scale" voucher to src/engine/vouchers.ts (tier-1, NO requires field),
copying the shape of the existing seed_money entry, and add a test to vouchers.test.ts
mirroring the seed_money test (assert effectiveInterestCap rises by 5).'
fi

# (2a) PARSE the spec generically: which catalog file, which sibling entry, which new id.
#   - catalog file: first src/engine/<name>.ts mentioned (env CATALOG_FILE overrides).
#   - new id:       NEW_ID env, else the first  id: "<x>"  in the spec.
#   - sibling id:   SIBLING_ID env, else the sibling named by the spec's "copy/mirror/shape of
#                   <id>" phrasing; fall back to the second id-looking token in the spec.
PARSE="$(python3 - "$WORKDIR/spec.txt" <<PY
import os, re, sys
spec = """$SPEC"""
open(sys.argv[1], "w").write(spec)  # stash for debugging
import shlex
def out(k, v): print(f"{k}={shlex.quote(str(v))}")

cat = os.environ.get("CATALOG_FILE", "").strip()
if not cat:
    m = re.search(r'src/engine/([A-Za-z0-9_]+)\.ts', spec)
    cat = f"src/engine/{m.group(1)}.ts" if m else "src/engine/vouchers.ts"
out("CATALOG_REL", cat)
out("TEST_REL", cat[:-3] + ".test.ts")

new_id = os.environ.get("NEW_ID", "").strip()
if not new_id:
    m = re.search(r'id\s*:\s*["\x27]([a-z0-9_]+)["\x27]', spec)
    new_id = m.group(1) if m else ""
out("NEW_ID", new_id)

# SIBLING id: gather candidates from cue phrases AND quoted/id tokens, in priority order, then
# the wrapping shell validates them against the REAL catalog file (the sibling MUST be an
# existing entry). We emit an ORDERED candidate list; the shell picks the first that exists.
STOP = {"an", "a", "the", "one", "existing", "sibling", "entry", "test", "shape", "of",
        "interest", "data", "catalog", "engine", "new", "same", "no", "not", new_id}
cands = []
def push(x):
    x = (x or "").strip().strip('"\'')
    if x and x not in STOP and x not in cands:
        cands.append(x)

sib_env = os.environ.get("SIBLING_ID", "").strip()
if sib_env:
    push(sib_env)
# (1) explicit "copy/mirror/shape of/sibling ... <id>" — but skip stop-words right after the cue
#     (handles "copy AN existing sibling seed_money": we scan a few tokens past the cue).
for m in re.finditer(r'(?:cop(?:y|ying)|mirror(?:ing)?|shape of|sibling)\b([^.\n]{0,60})', spec):
    for tok in re.findall(r'["\x27]?([a-z][a-z0-9_]+)["\x27]?', m.group(1)):
        push(tok)
# (2) "existing <id> (entry|test|joker|...)"
for m in re.finditer(r'\bexisting\s+([a-z][a-z0-9_]+)\b', spec):
    push(m.group(1))
# (3) any quoted snake_case id in the spec that isn't the new one (sibling ids usually have "_").
for m in re.finditer(r'["\x27]([a-z][a-z0-9]+(?:_[a-z0-9]+)+)["\x27]', spec):
    push(m.group(1))
# (4) last resort: any id: "<x>" token.
for x in re.findall(r'id\s*:\s*["\x27]([a-z0-9_]+)["\x27]', spec):
    push(x)
# Bias snake_case (real content ids) ahead of bare words, preserving discovery order within each.
cands = [c for c in cands if "_" in c] + [c for c in cands if "_" not in c]
out("SIBLING_CANDS", "|".join(cands))
out("SIBLING_ID", cands[0] if cands else "")
PY
)"
eval "$PARSE"
# Validate the sibling against the REAL catalog file: prefer the first candidate that exists as
# an  id: "<x>"  entry there. (Falls back to the parser's first candidate.)
CATALOG="$CLONE/$CATALOG_REL"
if [ -f "$CATALOG" ] && [ -n "${SIBLING_CANDS:-}" ]; then
  RESOLVED="$(python3 - "$CATALOG" "$SIBLING_CANDS" <<'PY'
import re, sys
cat = open(sys.argv[1]).read()
ids = set(re.findall(r'id\s*:\s*["\']([a-z0-9_]+)["\']', cat))
for c in sys.argv[2].split("|"):
    if c in ids:
        print(c); break
PY
)"
  [ -n "$RESOLVED" ] && SIBLING_ID="$RESOLVED"
fi
[ -n "$NEW_ID" ] || { add_note "could not parse a new entry id from the spec"; emit false none error none; }
[ -n "$SIBLING_ID" ] || { add_note "could not parse a sibling id from the spec"; emit false none error none; }
add_note "target: catalog=$CATALOG_REL test=$TEST_REL new_id=$NEW_ID sibling=$SIBLING_ID"

TESTF="$CLONE/$TEST_REL"
[ -f "$CATALOG" ] || { add_note "catalog file missing: $CATALOG_REL"; emit false none error none; }
[ -f "$TESTF" ]   || { add_note "test file missing: $TEST_REL"; emit false none error none; }

# (2b) Locate the CATALOG ARRAY CLOSE the sibling belongs to, and the SIBLING TEST anchor +
#      its enclosing DESCRIBE close. This is the generic version of the old hardcoded anchors.
#      Emits four numbers (1-based) the prompt-builder and fallback both consume:
#        CAT_CLOSE_LINE  — line of the "];" that closes the sibling's array
#        SIB_DESC_LINE   — line of the describe(...) that contains the sibling test
#        DESC_CLOSE_LINE — line of that describe's matching "});"
#        SIB_TEST_LINE   — line of the it(...)/test(...) opening the sibling's test block
ANCH="$(python3 - "$CATALOG" "$TESTF" "$SIBLING_ID" <<'PY'
import sys, re
cat_path, test_path, sib = sys.argv[1:4]
import shlex
def out(k, v): print(f"{k}={shlex.quote(str(v))}")

cat = open(cat_path).read().splitlines()
# Catalog array close: find the line that DEFINES the sibling (id: "sib"), then the first
# array-closing "];" at/after it. "];" may be column-0 or indented; match a line whose strip()
# is exactly "];". (Falls back to the LAST "];" if the sibling id isn't found.)
sib_def = next((i for i, s in enumerate(cat)
                if re.search(r'id\s*:\s*["\']' + re.escape(sib) + r'["\']', s)), None)
if sib_def is None:
    closes = [i for i, s in enumerate(cat) if s.strip() == '];']
    cat_close = closes[-1] if closes else len(cat) - 1
else:
    cat_close = next((i for i in range(sib_def, len(cat)) if cat[i].strip() == '];'),
                     max(i for i, s in enumerate(cat) if s.strip() == '];'))
out("CAT_CLOSE_LINE", cat_close + 1)

test = open(test_path).read().splitlines()
# Sibling test: the it(...)/test(...) block whose body references the sibling id (it appears in
# the test body, e.g. push("seed_money") / getJoker("gluttonous_joker") / useConsumable(...,"medium")).
# Find the line mentioning the sibling id, then the nearest test-opener line at or above it.
opener = re.compile(r'^\s*(it|test)(\.\w+)?\s*\(')
ref = next((i for i, s in enumerate(test)
            if re.search(r'["\']' + re.escape(sib) + r'["\']', s)), None)
sib_test = None
if ref is not None:
    for i in range(ref, -1, -1):
        if opener.search(test[i]): sib_test = i; break
if sib_test is None:  # fall back: any opener whose string mentions a humanized sibling
    human = sib.replace('_', ' ')
    sib_test = next((i for i, s in enumerate(test)
                     if opener.search(s) and human.lower() in s.lower()), None)
out("SIB_TEST_LINE", (sib_test + 1) if sib_test is not None else 0)

# Enclosing describe of the sibling test: nearest describe(...) opener above it; then its
# matching "});" by brace/paren depth.
desc = re.compile(r'^\s*describe\s*\(')
sib_desc = None
if sib_test is not None:
    for i in range(sib_test, -1, -1):
        if desc.search(test[i]): sib_desc = i; break
if sib_desc is None:
    sib_desc = next((i for i, s in enumerate(test) if desc.search(s)), 0)
out("SIB_DESC_LINE", sib_desc + 1)
depth = 0; close = None
for i in range(sib_desc, len(test)):
    depth += test[i].count('{') - test[i].count('}')
    if i > sib_desc and depth <= 0: close = i; break
out("DESC_CLOSE_LINE", (close + 1) if close is not None else len(test))
PY
)"
eval "$ANCH"
add_note "anchors: cat_close=$CAT_CLOSE_LINE sib_test=$SIB_TEST_LINE sib_describe=$SIB_DESC_LINE describe_close=$DESC_CLOSE_LINE"

# Build the prompt context windows from the located anchors (not blind file tails):
#   - catalog: ~30 lines ending at the array close (so the sibling + "];" are in view).
#   - test:    the full sibling describe block (opener .. close).
CAT_CTX="$(python3 -c '
import sys
src=open(sys.argv[1]).read().splitlines(); close=int(sys.argv[2])
start=max(0, close-30)
print("\n".join(src[start:close]))' "$CATALOG" "$CAT_CLOSE_LINE")"
TEST_CTX="$(python3 -c '
import sys
src=open(sys.argv[1]).read().splitlines(); a=int(sys.argv[2])-1; b=int(sys.argv[3])
print("\n".join(src[a:b]))' "$TESTF" "$SIB_DESC_LINE" "$DESC_CLOSE_LINE")"

# (3) ONE constrained model call -> unified diff (same shape as the proven base)
PROMPT_FILE="$WORKDIR/prompt.txt"
cat >"$PROMPT_FILE" <<EOF
You are a precise patch generator. Output ONLY a unified diff, nothing else.

TASK (mechanical, ADD-ONLY): $SPEC

You are adding ONE new entry with id "$NEW_ID" to $CATALOG_REL, copying the shape of the
existing "$SIBLING_ID" entry, and ONE new test to $TEST_REL mirroring the existing
"$SIBLING_ID" test.

Produce a unified diff with EXACTLY TWO hunks (one per file). It is PURELY ADDITIVE: every
content line in each hunk is either an UNCHANGED context line (leading single space, copied
VERBATIM from the file below) or an ADDED line (leading "+"). There are ZERO "-" lines.

HUNK 1 — $CATALOG_REL
The array ends with the LAST entry then a line "];". Anchor on the lines shown below. Insert
the new "$NEW_ID" object (added "+" lines) AFTER the last entry's closing "}," / "}" and BEFORE
the "];" line. Do NOT reprint or modify any existing entry — existing lines you show must be
unchanged context (leading space), byte-for-byte.

HUNK 2 — $TEST_REL
Inside the describe(...) block shown below (the one holding the "$SIBLING_ID" test), AFTER the
"$SIBLING_ID" test block's closing "});" and BEFORE the describe's own closing "});", insert a
NEW it(...) block (added "+" lines) that mirrors the "$SIBLING_ID" test for "$NEW_ID". Show the
sibling test block's last lines as unchanged context, byte-for-byte.

FORMAT (follow this skeleton EXACTLY; "@@ @@" with no line numbers is fine — the applier
recounts):
--- a/$CATALOG_REL
+++ b/$CATALOG_REL
@@ @@
 <unchanged context line copied verbatim>
 <unchanged context line copied verbatim>
+    {
+      id: "$NEW_ID",
+      ...added lines...
+    },
 ];
--- a/$TEST_REL
+++ b/$TEST_REL
@@ @@
 <unchanged context line copied verbatim>
+
+  it("...$NEW_ID...", () => {
+    ...added lines...
+  });
 });

RULES: output starts immediately with "--- a/". No prose, no markdown fences. Context lines
copied EXACTLY (same indentation/punctuation). Only "+" and " " lines, never "-".

=== CONTEXT of $CATALOG_REL (ends at the array close — anchor your first hunk here) ===
$CAT_CTX

=== CONTEXT of $TEST_REL (the describe block holding the "$SIBLING_ID" test — anchor hunk 2 here) ===
$TEST_CTX

Now output ONLY the unified diff.
EOF

err "calling model $MODEL (cold-load may take up to 120s)..."
REQ_FILE="$WORKDIR/req.json"
python3 - "$MODEL" "$PROMPT_FILE" >"$REQ_FILE" <<'PY'
import json, sys
print(json.dumps({"model": sys.argv[1], "stream": False,
    "options": {"temperature": 0, "num_ctx": 8192},
    "messages": [
        {"role": "system", "content": "You output only unified diffs. No prose. No code fences."},
        {"role": "user", "content": open(sys.argv[2]).read()}]}))
PY
RESP_FILE="$WORKDIR/resp.json"; RAW=""
for attempt in 1 2; do
  if curl -s --max-time 120 "$OLLAMA_URL/api/chat" -d @"$REQ_FILE" >"$RESP_FILE" 2>/dev/null; then
    RAW="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["message"]["content"])' "$RESP_FILE" 2>/dev/null)"
    [ -n "$RAW" ] && break
  fi
  add_note "model call attempt $attempt empty/failed; retrying"; sleep 2
done
[ -z "$RAW" ] && { add_note "no response from model after 2 attempts"; emit false none none none; }

# (3b) extract diff straight from resp.json (round-tripping through a shell var mangles UTF-8)
DIFF_FILE="$WORKDIR/model.diff"
python3 - "$RESP_FILE" >"$DIFF_FILE" <<'PY'
import sys, re, json
raw = json.load(open(sys.argv[1]))["message"]["content"]
raw = re.sub(r'^```[a-zA-Z]*\s*$', '', raw, flags=re.M).replace('```', '')
lines = raw.splitlines(); start = 0
for i, l in enumerate(lines):
    if l.startswith('diff --git') or l.startswith('--- a/') or l.startswith('--- '):
        start = i; break
sys.stdout.write("\n".join(lines[start:]).rstrip() + "\n")
PY
grep -q '^---\|^diff --git' "$DIFF_FILE" || { add_note "model output contained no diff markers"; emit false none none none; }

# (4) apply: git apply (several strategies) -> deterministic anchor-insert fallback (the
#     reliable path for small models). Anchors are the GENERIC ones computed above:
#       catalog  -> before CAT_CLOSE_LINE (close of the sibling's array)
#       testfile -> before DESC_CLOSE_LINE (close of the sibling's describe)
APPLY_METHOD="none"; APPLIED=false
for opts in "" "--recount" "--ignore-whitespace" "--recount --ignore-whitespace" "--3way" "--recount --3way"; do
  if git -C "$CLONE" apply --whitespace=nowarn $opts "$DIFF_FILE" >/dev/null 2>&1; then
    APPLIED=true; APPLY_METHOD="git apply ${opts:-(plain)}"; add_note "applied with: $APPLY_METHOD"; break
  fi
done

if [ "$APPLIED" != true ]; then
  add_note "git apply failed for all strategies; trying deterministic anchor-insert"
  if python3 - "$DIFF_FILE" "$CATALOG" "$TESTF" "$CATALOG_REL" "$TEST_REL" "$NEW_ID" "$CAT_CLOSE_LINE" "$DESC_CLOSE_LINE" <<'PY'
import sys
diff_path, catalog_path, test_path, cat_rel, test_rel, new_id, cat_close, desc_close = sys.argv[1:9]
cat_close = int(cat_close); desc_close = int(desc_close)
cat_base = cat_rel.split('/')[-1]; test_base = test_rel.split('/')[-1]

lines = open(diff_path, errors="replace").read().splitlines()
added = {}; cur = None
for l in lines:
    if l.startswith('+++ '):
        p = l[4:].strip(); p = p[2:] if p.startswith('b/') else p
        cur = p; added.setdefault(cur, []); continue
    if l.startswith('--- ') or l.startswith('diff ') or l.startswith('@@'): continue
    if cur is None: continue
    if l.startswith('+'): added[cur].append(l[1:])

ok = True
# Match added blocks back to the two target files by basename (model may path them a/ or b/).
cat_add  = next((v for k, v in added.items() if k.endswith(cat_base)), [])
test_add = next((v for k, v in added.items() if k.endswith(test_base)), [])

if not cat_add or not any(new_id in x for x in cat_add):
    sys.stderr.write(f"fallback: no '{new_id}' added-lines for {cat_base}\n"); ok = False
else:
    src = open(catalog_path).read().splitlines()
    idx = cat_close - 1  # insert BEFORE the array-close line
    if idx < 0 or idx > len(src) or src[idx].strip() != '];':
        # anchor drifted (model added context shifting nothing yet, file unchanged) — recompute
        closes = [i for i, s in enumerate(src) if s.strip() == '];']
        idx = closes[-1] if closes else len(src)
    # Brace-balance the added entry block. Small models sometimes emit the object's opening
    # "{" (or closing "},") as a CONTEXT line, so it never reaches cat_add -> a malformed,
    # non-parsing entry. Repair by matching brace counts and prepending/appending as needed.
    _nb = [x for x in cat_add if x.strip()]
    if _nb:
        _op = sum(x.count('{') for x in cat_add); _cl = sum(x.count('}') for x in cat_add)
        _first, _last = _nb[0], _nb[-1]
        _ind = _first[:len(_first) - len(_first.lstrip())]
        _par = _ind[:-2] if len(_ind) >= 2 else _ind   # object-brace (parent) indent
        if _cl > _op and not _first.lstrip().startswith('{'):
            cat_add = [_par + '{'] + cat_add
        elif _op > _cl and not _last.rstrip().rstrip(',').endswith('}'):
            cat_add = cat_add + [_par + '},']
    open(catalog_path, 'w').write("\n".join(src[:idx] + cat_add + src[idx:]) + "\n")

if not test_add or not any(new_id in x for x in test_add):
    sys.stderr.write(f"fallback: no '{new_id}' added-lines for {test_base}\n"); ok = False
else:
    src = open(test_path).read().splitlines()
    idx = desc_close - 1  # insert BEFORE the describe-close line
    if idx < 0 or idx >= len(src):
        sys.stderr.write("fallback: describe close out of range\n"); ok = False
    else:
        open(test_path, 'w').write("\n".join(src[:idx] + test_add + src[idx:]) + "\n")

sys.exit(0 if ok else 1)
PY
  then APPLIED=true; APPLY_METHOD="deterministic anchor-insert"; add_note "applied with: $APPLY_METHOD"; fi
fi
if [ "$APPLIED" != true ]; then
  add_note "all apply strategies failed (incl. anchor-insert)"
  err "----- model diff that failed to apply -----"; cat "$DIFF_FILE" >&2; err "-------------------------------------------"
  emit false none none none
fi

# (5) guard, then bun install + bun test on the touched test file
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
emit "$APPLIED" "$APPLY_METHOD" "$GUARD_RESULT" "$TESTS"
