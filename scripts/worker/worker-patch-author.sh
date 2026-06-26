#!/usr/bin/env bash
# worker-patch-author.sh — the AUTHORING CORE of the constrained patch-apply worker (PET-182).
#
# Extracted verbatim from worker-patch-run.sh so there is ONE authoring implementation shared by
# two callers: the standalone test harness (worker-patch-run.sh) and the production worker loop
# (worker-run.sh, WORKER_AUTHOR_MODE=patch). This script does ONLY authoring — it mutates an
# ALREADY-CLONED, already-checked-out working tree in place. It does NOT clone, guard, test, or
# push (the caller owns those).
#
# Mechanics — TEMPLATE-INSERT (PET-182). The original two-hunk-diff approach failed on 7B
# models (they emit one hunk and drop the other — the catalog add went missing); authoring is
# now content-substitution off a verbatim sibling template, which small models copy reliably:
#   * parse the spec generically (catalog file + new id + sibling id, sibling validated against
#     the real catalog);
#   * locate anchors (the sibling's catalog-array close "];" and the sibling test's enclosing
#     describe close) AND extract the sibling's catalog object + test block VERBATIM;
#   * focused model calls (/api/chat, temp 0, num_ctx 8192): "copy this sibling object → emit
#     ONLY the new object", and (only when the sibling HAS a standalone test) "copy this sibling
#     test → emit ONLY the new it(...) block";
#   * clean each to its balanced block, re-indent to the sibling, validate it carries the new id,
#     then ATOMICALLY insert at the anchors (both blocks or NEITHER — never a half-write).
#   * NO-SIBLING-TEST case: when the chosen sibling is covered ONLY by the catalog-enumeration
#     test (no standalone it(...) to mirror, SIB_TEST_LINE=0), SKIP the per-id test entirely and
#     author ONLY the catalog entry — never ask the 7B model to invent a test with no template
#     (it hallucinates a broken one, e.g. `getTarotById is not defined`, which fails the suite and
#     blocks the reconciler). The new entry stays covered by the catalog-enumeration test, which
#     worker-reconcile-asserts.sh bumps. Guard stays OK: tests net 0, never negative. (PET-179.)
#
# Usage:  worker-patch-author.sh <clone-dir> <ollama-model-tag>
# Env:    SPEC_FILE (required, path to the task spec), OLLAMA_URL (default homelab ollama),
#         SCRATCH (work/scratch dir; default mktemp), CATALOG_FILE/NEW_ID/SIBLING_ID overrides.
# Output: last stdout line is JSON {"applied","apply_method","catalog_file","test_file",
#         "new_id","sibling_id","notes"}. Exit 0 iff the working tree was mutated (applied),
#         1 otherwise (parse/model/apply failure — notes carry the reason).
set -uo pipefail

CLONE="${1:?usage: worker-patch-author.sh <clone-dir> <ollama-model-tag>}"
MODEL="${2:?usage: worker-patch-author.sh <clone-dir> <ollama-model-tag>}"
OLLAMA_URL="${OLLAMA_URL:-http://192.168.50.12:11434}"
SCRATCH="${SCRATCH:-$(mktemp -d "${TMPDIR:-/tmp}/worker-author-XXXXXX")}"
mkdir -p "$SCRATCH" 2>/dev/null || true   # a caller-supplied SCRATCH (e.g. $ART/author) may not exist yet
err() { printf '[author] %s\n' "$*" >&2; }
NOTES=""
add_note() { NOTES="${NOTES:+$NOTES; }$1"; err "$1"; }

# Filled in once we parse the spec; emitted in the JSON verdict.
CATALOG_REL=""; TEST_REL=""; NEW_ID=""; SIBLING_ID=""
emit() {  # $1 applied(bool) $2 apply_method  → JSON verdict + exit code (0 applied, 1 not)
  python3 - "$MODEL" "$1" "$2" "$NOTES" "$CATALOG_REL" "$TEST_REL" "$NEW_ID" "$SIBLING_ID" <<'PY'
import json, sys
m, applied, method, notes, cat, test, nid, sib = sys.argv[1:9]
print(json.dumps({"model": m, "applied": applied == "true", "apply_method": method,
                  "catalog_file": cat, "test_file": test, "new_id": nid, "sibling_id": sib,
                  "notes": notes}))
PY
  [ "$1" = "true" ] && exit 0 || exit 1
}

[ -d "$CLONE/.git" ] || { add_note "clone dir is not a git checkout: $CLONE"; emit false none; }

# (1) read spec
SPEC_FILE="${SPEC_FILE:-}"
if [ -n "$SPEC_FILE" ] && [ -f "$SPEC_FILE" ]; then
  SPEC="$(cat "$SPEC_FILE")"
else
  add_note "SPEC_FILE missing/unreadable: ${SPEC_FILE:-<unset>}"; emit false none
fi

# (2) PARSE the spec generically: which catalog file, which sibling entry, which new id.
PARSE="$(python3 - "$SCRATCH/spec.txt" <<PY
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
for m in re.finditer(r'(?:cop(?:y|ying)|mirror(?:ing)?|shape of|sibling)\b([^.\n]{0,60})', spec):
    for tok in re.findall(r'["\x27]?([a-z][a-z0-9_]+)["\x27]?', m.group(1)):
        push(tok)
for m in re.finditer(r'\bexisting\s+([a-z][a-z0-9_]+)\b', spec):
    push(m.group(1))
for m in re.finditer(r'["\x27]([a-z][a-z0-9]+(?:_[a-z0-9]+)+)["\x27]', spec):
    push(m.group(1))
for x in re.findall(r'id\s*:\s*["\x27]([a-z0-9_]+)["\x27]', spec):
    push(x)
cands = [c for c in cands if "_" in c] + [c for c in cands if "_" not in c]
out("SIBLING_CANDS", "|".join(cands))
out("SIBLING_ID", cands[0] if cands else "")
PY
)"
eval "$PARSE"
# Validate the sibling against the REAL catalog file: prefer the first candidate that exists.
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
[ -n "$NEW_ID" ] || { add_note "could not parse a new entry id from the spec"; emit false none; }
[ -n "$SIBLING_ID" ] || { add_note "could not parse a sibling id from the spec"; emit false none; }
add_note "target: catalog=$CATALOG_REL test=$TEST_REL new_id=$NEW_ID sibling=$SIBLING_ID"

TESTF="$CLONE/$TEST_REL"
[ -f "$CATALOG" ] || { add_note "catalog file missing: $CATALOG_REL"; emit false none; }
[ -f "$TESTF" ]   || { add_note "test file missing: $TEST_REL"; emit false none; }

# (2b) Locate the CATALOG ARRAY CLOSE the sibling belongs to, and the SIBLING TEST anchor +
#      its enclosing DESCRIBE close.
ANCH="$(python3 - "$CATALOG" "$TESTF" "$SIBLING_ID" <<'PY'
import sys, re
cat_path, test_path, sib = sys.argv[1:4]
import shlex
def out(k, v): print(f"{k}={shlex.quote(str(v))}")

cat = open(cat_path).read().splitlines()
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
opener = re.compile(r'^\s*(it|test)(\.\w+)?\s*\(')
ref = next((i for i, s in enumerate(test)
            if re.search(r'["\']' + re.escape(sib) + r'["\']', s)), None)
sib_test = None
if ref is not None:
    for i in range(ref, -1, -1):
        if opener.search(test[i]): sib_test = i; break
if sib_test is None:
    human = sib.replace('_', ' ')
    sib_test = next((i for i, s in enumerate(test)
                     if opener.search(s) and human.lower() in s.lower()), None)
out("SIB_TEST_LINE", (sib_test + 1) if sib_test is not None else 0)

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

# (2c) Extract the SIBLING templates VERBATIM. Authoring is then a content-substitution the
#      model copies (reliable on 7B) rather than multi-hunk diff geometry (which 7B models drop
#      — PET-182 bake-off: the model emitted the test hunk but left the catalog hunk empty).
SIB_OBJ="$SCRATCH/sib_obj.txt"; SIB_TESTB="$SCRATCH/sib_test.txt"
python3 - "$CATALOG" "$TESTF" "$SIBLING_ID" "$SIB_TEST_LINE" "$SIB_OBJ" "$SIB_TESTB" <<'PY'
import sys, re
cat_path, test_path, sib, sib_test_line, obj_out, test_out = sys.argv[1:7]
sib_test_line = int(sib_test_line)
cat = open(cat_path).read().splitlines()
# Catalog object: entry whose body has  id: "sib". Opener = nearest '{'-only line above; closer
# = brace-match down to depth 0.
sid = next((i for i, s in enumerate(cat)
            if re.search(r'id\s*:\s*["\']' + re.escape(sib) + r'["\']', s)), None)
obj = []
if sid is not None:
    op = next((i for i in range(sid, -1, -1) if cat[i].strip() == '{'), sid)
    depth = 0
    for i in range(op, len(cat)):
        depth += cat[i].count('{') - cat[i].count('}')
        obj.append(cat[i])
        if i > op and depth <= 0: break
open(obj_out, 'w').write("\n".join(obj) + "\n")
# Test block: from the sibling it(...) opener (1-based) brace-match to its close ('});').
test = open(test_path).read().splitlines()
tb = []
if sib_test_line > 0:
    st = sib_test_line - 1
    depth = 0; started = False
    for i in range(st, len(test)):
        depth += test[i].count('{') - test[i].count('}')
        tb.append(test[i])
        if '{' in test[i]: started = True
        if started and depth <= 0: break
open(test_out, 'w').write("\n".join(tb) + "\n")
PY
[ -s "$SIB_OBJ" ]   || { add_note "could not extract sibling catalog object for $SIBLING_ID"; emit false none; }

# EMIT_TEST: only author a per-id acceptance test when the sibling HAS a standalone it(...) test
# to copy (SIB_TEST_LINE>0 AND a non-empty extracted template). When the sibling is covered ONLY
# by the catalog-enumeration test (no standalone test — e.g. the_hierophant), there is no
# template to mirror; asking the 7B model to invent one makes it HALLUCINATE a broken test
# (`getTarotById is not defined` etc.) that fails the suite and blocks the reconciler. In that
# case we SKIP the test entirely and author ONLY the catalog entry — the new id stays covered by
# the catalog-enumeration test (which the reconciler bumps). Guard stays OK: tests net 0 (a no-op
# on the test count), never negative. (242 end-to-end finding, PET-179.)
EMIT_TEST=true
if [ "${SIB_TEST_LINE:-0}" -eq 0 ] || [ ! -s "$SIB_TESTB" ]; then
  EMIT_TEST=false
  add_note "no standalone test for sibling $SIBLING_ID — skipping per-id test; entry covered by the catalog-enumeration test"
fi

# (3) Two FOCUSED model calls: emit ONLY the new catalog object, and ONLY the new test block,
#     each copying the corresponding sibling template. No diff format (small models botch it).
call_model() {  # $1 system  $2 user-prompt-file  $3 tag  $4 out-file (raw message content)
  local req="$SCRATCH/req.$3.json" resp="$SCRATCH/resp.$3.json"
  python3 - "$MODEL" "$1" "$2" >"$req" <<'PY'
import json, sys
print(json.dumps({"model": sys.argv[1], "stream": False,
    "options": {"temperature": 0, "num_ctx": 8192},
    "messages": [{"role": "system", "content": sys.argv[2]},
                 {"role": "user", "content": open(sys.argv[3]).read()}]}))
PY
  : >"$4"
  for attempt in 1 2; do
    if curl -s --max-time 120 "$OLLAMA_URL/api/chat" -d @"$req" >"$resp" 2>/dev/null; then
      python3 -c 'import json,sys; open(sys.argv[2],"w").write(json.load(open(sys.argv[1]))["message"]["content"])' "$resp" "$4" 2>/dev/null
      [ -s "$4" ] && break
    fi
    sleep 2
  done
}

UOBJ="$SCRATCH/u_obj.txt"
cat >"$UOBJ" <<EOF
TASK (mechanical, ADD-ONLY): $SPEC

Here is the existing "$SIBLING_ID" entry from $CATALOG_REL:

$(cat "$SIB_OBJ")

Produce ONE new entry for id "$NEW_ID" by copying this entry's EXACT shape and changing ONLY
what the task requires (id, name, and the specific field(s) the task names). Keep every other
field identical. Output ONLY the new TypeScript object literal — start with "{" and end with
"}," — no prose, no markdown fences, no diff markers, no surrounding array brackets.
EOF

UTEST="$SCRATCH/u_test.txt"
cat >"$UTEST" <<EOF
TASK (mechanical, ADD-ONLY): $SPEC

Here is the existing "$SIBLING_ID" test from $TEST_REL:

$(cat "$SIB_TESTB")

Produce ONE new test for "$NEW_ID" that mirrors this test EXACTLY, changing ONLY the id/name
string(s) and the asserted value(s) the task requires. Output ONLY the new it(...) block —
start with "it(" and end with "});" — no prose, no markdown fences, no diff markers.
EOF

NEW_OBJ="$SCRATCH/new_obj.txt"; NEW_TESTB="$SCRATCH/new_test.txt"
: >"$NEW_TESTB"   # empty by default; only filled when EMIT_TEST=true
if [ "$EMIT_TEST" = true ]; then
  err "calling model $MODEL for the new catalog entry + test (cold-load may take up to 120s)..."
else
  err "calling model $MODEL for the new catalog entry ONLY (no sibling test to mirror)..."
fi
call_model "You output only a single TypeScript object literal. No prose, no code fences, no diff." \
           "$UOBJ" obj "$NEW_OBJ"
if [ "$EMIT_TEST" = true ]; then
  call_model "You output only a single it(...) test block. No prose, no code fences, no diff." \
             "$UTEST" test "$NEW_TESTB"
fi
# The catalog object is always required; the test only when we chose to emit one.
[ -s "$NEW_OBJ" ] || { add_note "model returned an empty catalog object"; emit false none; }
if [ "$EMIT_TEST" = true ] && [ ! -s "$NEW_TESTB" ]; then
  add_note "model returned an empty test block"; emit false none
fi

# (4) clean + validate + ATOMIC insert. When EMIT_TEST=true: both blocks or NEITHER (never a
#     half-write). When EMIT_TEST=false: ONLY the catalog entry (no test to write).
APPLY_METHOD="none"; APPLIED=false
if EMIT_TEST="$EMIT_TEST" python3 - "$CATALOG" "$TESTF" "$NEW_OBJ" "$NEW_TESTB" "$SIB_OBJ" "$SIB_TESTB" "$NEW_ID" "$CAT_CLOSE_LINE" "$DESC_CLOSE_LINE" <<'PY'
import os, sys, re
cat_path, test_path, obj_raw_p, test_raw_p, sib_obj_p, sib_test_p, new_id, cat_close, desc_close = sys.argv[1:10]
cat_close = int(cat_close); desc_close = int(desc_close)
emit_test = os.environ.get("EMIT_TEST", "true") == "true"

def defence(txt):
    return txt.replace('```', '')

def extract_braced(txt, start_pat=None):
    lines = defence(txt).splitlines()
    if start_pat:
        s = next((i for i, l in enumerate(lines) if start_pat.search(l)), None)
    else:
        s = next((i for i, l in enumerate(lines) if '{' in l), None)
    if s is None:
        return None
    depth = 0; started = False; out = []
    for i in range(s, len(lines)):
        l = lines[i]
        depth += l.count('{') - l.count('}')
        out.append(l)
        if '{' in l: started = True
        if started and depth <= 0:
            return out
    return None

def base_indent(l):
    return len(l) - len(l.lstrip())

def reindent(block, target):
    first = next((l for l in block if l.strip()), block[0])
    delta = target - base_indent(first)
    out = []
    for l in block:
        if not l.strip():
            out.append(l)
        elif delta >= 0:
            out.append(' ' * delta + l)
        else:
            out.append(l[min(-delta, base_indent(l)):])
    return out

sib_obj = open(sib_obj_p).read().splitlines()
obj = extract_braced(open(obj_raw_p).read())

# The catalog object is always required and must carry the new id.
ok = obj is not None
if ok and not any(new_id in l for l in obj):  sys.stderr.write("new catalog object missing the new id\n"); ok = False

# The test is OPTIONAL: only when a sibling standalone test existed to mirror (emit_test).
test = None
if emit_test:
    sib_test = open(sib_test_p).read().splitlines()
    test = extract_braced(open(test_raw_p).read(), re.compile(r'\b(it|test)\s*\('))
    if ok and test is None:
        sys.stderr.write("emit_test set but no test block extracted\n"); ok = False
    if ok and not any(new_id in l for l in test): sys.stderr.write("new test missing the new id\n"); ok = False
if not ok:
    sys.exit(1)

while obj and not obj[-1].strip(): obj.pop()
if obj and not obj[-1].rstrip().endswith(','):       # ensure the entry ends with "},"
    obj[-1] = obj[-1].rstrip() + ','
obj = reindent(obj, base_indent(sib_obj[0]) if sib_obj else 2)

csrc = open(cat_path).read().splitlines()
ci = cat_close - 1
if ci < 0 or ci > len(csrc) or csrc[ci].strip() != '];':
    closes = [i for i, s in enumerate(csrc) if s.strip() == '];']
    ci = closes[-1] if closes else len(csrc)

if test is not None:
    sib_test = open(sib_test_p).read().splitlines()
    while test and not test[-1].strip(): test.pop()
    test = [''] + reindent(test, base_indent(sib_test[0]) if sib_test else 2)  # blank line before the new test
    tsrc = open(test_path).read().splitlines()
    ti = desc_close - 1
    if ti < 0 or ti > len(tsrc):
        sys.stderr.write("describe close out of range\n"); sys.exit(1)
    # Both validated → write BOTH (atomic): catalog entry + per-id test.
    open(cat_path, 'w').write("\n".join(csrc[:ci] + obj + csrc[ci:]) + "\n")
    open(test_path, 'w').write("\n".join(tsrc[:ti] + test + tsrc[ti:]) + "\n")
else:
    # No sibling test to mirror → write ONLY the catalog entry. The test file is untouched, so
    # the test count is unchanged (guard net 0 on tests, never negative).
    open(cat_path, 'w').write("\n".join(csrc[:ci] + obj + csrc[ci:]) + "\n")
sys.exit(0)
PY
then
  APPLIED=true
  if [ "$EMIT_TEST" = true ]; then
    APPLY_METHOD="template-insert"; add_note "applied (template-insert): new entry + test for $NEW_ID"
  else
    APPLY_METHOD="template-insert-entry-only"; add_note "applied (entry-only): new catalog entry for $NEW_ID (no per-id test — covered by the catalog-enumeration test)"
  fi
else add_note "template extraction/validation failed — wrote nothing (atomic)"; emit false none; fi

emit "$APPLIED" "$APPLY_METHOD"
