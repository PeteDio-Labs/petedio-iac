#!/usr/bin/env bash
# worker-patch-apply.sh — CONSTRAINED single-shot patch-apply worker harness (PET-173/PET-133).
#
# An alternative to opencode agentic editing, which fails with local models (they overwrite
# or no-op). For a MECHANICAL catalog-add (the spec contains the EXACT entry) we make ONE
# non-agentic model call asking for an ADD-ONLY unified diff, then apply it deterministically
# (git apply best-effort, then a deterministic anchor-insert of the model's "+" lines) and gate
# it with the additive guard + `bun test`.
#
# Usage:  worker-patch-apply.sh <ollama-model-tag>          e.g. worker-patch-apply.sh qwen2.5-coder:7b
# Env:    OLLAMA_URL (default http://192.168.50.12:11434), REPO (default PeteDio-Labs/co-latro-backend),
#         SPEC_FILE, GUARD (path to worker-guard-additive.sh), WORKDIR, KEEP=1.
# Output: per-model JSON on stdout: {"model","diff_applied","apply_method","guard","tests","notes"}.
#         Exit 0 always (JSON carries the verdict); exit 1 only on a harness/usage error.
set -uo pipefail

MODEL="${1:?usage: worker-patch-apply.sh <ollama-model-tag>}"
OLLAMA_URL="${OLLAMA_URL:-http://192.168.50.12:11434}"
REPO="${REPO:-PeteDio-Labs/co-latro-backend}"
KEEP="${KEEP:-0}"
err() { printf '[harness] %s\n' "$*" >&2; }
WORKDIR="${WORKDIR:-$(mktemp -d "${TMPDIR:-/tmp}/worker-patch-XXXXXX")}"
CLONE="$WORKDIR/repo"
NOTES=""
add_note() { NOTES="${NOTES:+$NOTES; }$1"; err "$1"; }

emit() {  # $1 diff_applied(bool) $2 apply_method $3 guard $4 tests
  python3 - "$MODEL" "$1" "$2" "$3" "$4" "$NOTES" <<'PY'
import json, sys
m, applied, method, guard, tests, notes = sys.argv[1:7]
print(json.dumps({"model": m, "diff_applied": applied == "true", "apply_method": method,
                  "guard": guard, "tests": tests, "notes": notes}))
PY
  [ "$KEEP" = "1" ] || rm -rf "$WORKDIR"
  exit 0
}

# (1) fresh clone + checkout main
err "cloning $REPO -> $CLONE"
gh repo clone "$REPO" "$CLONE" -- --depth 1 >/dev/null 2>&1 || { add_note "clone failed"; emit false none error none; }
git -C "$CLONE" checkout main >/dev/null 2>&1 || git -C "$CLONE" checkout -B main >/dev/null 2>&1
VOUCHERS="$CLONE/src/engine/vouchers.ts"; VTEST="$CLONE/src/engine/vouchers.test.ts"
[ -f "$VOUCHERS" ] || { add_note "vouchers.ts missing"; emit false none error none; }
GUARD="${GUARD:-}"
if [ -z "$GUARD" ]; then
  for cand in "$(dirname "$0")/worker-guard-additive.sh" \
              "/home/agent/work/petedio/iac/scripts/worker/worker-guard-additive.sh"; do
    [ -f "$cand" ] && { GUARD="$cand"; break; }
  done
fi

# (2) read spec + current files
SPEC_FILE="${SPEC_FILE:-}"
if [ -n "$SPEC_FILE" ] && [ -f "$SPEC_FILE" ]; then
  SPEC="$(cat "$SPEC_FILE")"
else
  SPEC='Append a "fortune_scale" voucher to src/engine/vouchers.ts (tier-1, NO requires field),
copying the shape of the existing seed_money entry, and add a test to vouchers.test.ts
mirroring the seed_money test (assert effectiveInterestCap rises by 5).'
fi
VFILE_TAIL="$(tail -n 40 "$VOUCHERS")"

# (3) ONE constrained model call -> unified diff
PROMPT_FILE="$WORKDIR/prompt.txt"
cat >"$PROMPT_FILE" <<EOF
You are a precise patch generator. Output ONLY a unified diff, nothing else.

TASK (mechanical, ADD-ONLY): $SPEC

Produce a unified diff with EXACTLY TWO hunks (one per file). It is PURELY ADDITIVE: every
content line in each hunk is either an UNCHANGED context line (leading single space, copied
VERBATIM from the file below) or an ADDED line (leading "+"). There are ZERO "-" lines.

HUNK 1 — src/engine/vouchers.ts
The file ends with the LAST voucher entry then a line "];". Anchor the hunk on the last few
lines shown below. Insert the new fortune_scale object (added "+" lines) AFTER the last entry's
closing "}," and BEFORE the "];" line. Do NOT reprint or modify any existing entry's fields —
the existing lines you show must appear as unchanged context (leading space), byte-for-byte.

HUNK 2 — src/engine/vouchers.test.ts
Inside describe("vouchers — effective caps", ...), AFTER the Seed Money it(...) block's closing
"});" and BEFORE the describe's own closing "});", insert a NEW it("Fortune Scale ...") block
(added "+" lines) that mirrors the Seed Money test for "fortune_scale". Show the Seed Money
block's last lines as unchanged context, byte-for-byte.

FORMAT (follow this skeleton EXACTLY; "@@ @@" with no line numbers is fine — the applier
recounts):
--- a/src/engine/vouchers.ts
+++ b/src/engine/vouchers.ts
@@ @@
 <unchanged context line copied verbatim>
 <unchanged context line copied verbatim>
+    {
+      id: "fortune_scale",
+      ...added lines...
+    },
 ];
--- a/src/engine/vouchers.test.ts
+++ b/src/engine/vouchers.test.ts
@@ @@
 <unchanged context line copied verbatim>
+
+  it("Fortune Scale ...", () => {
+    ...added lines...
+  });
 });

RULES: output starts immediately with "--- a/". No prose, no markdown fences. Context lines
copied EXACTLY (same indentation/punctuation). Only "+" and " " lines, never "-".

=== TAIL of src/engine/vouchers.ts (anchor your first hunk here) ===
$VFILE_TAIL

=== FULL src/engine/vouchers.test.ts (anchor your second hunk on the Seed Money test) ===
$(cat "$VTEST")

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

# (4) apply: git apply (several strategies) -> deterministic anchor-insert fallback
APPLY_METHOD="none"; APPLIED=false
for opts in "" "--recount" "--ignore-whitespace" "--recount --ignore-whitespace" "--3way" "--recount --3way"; do
  if git -C "$CLONE" apply --whitespace=nowarn $opts "$DIFF_FILE" >/dev/null 2>&1; then
    APPLIED=true; APPLY_METHOD="git apply ${opts:-(plain)}"; add_note "applied with: $APPLY_METHOD"; break
  fi
done

# Fallback: small models botch hunk geometry even when the ADDED block is right. For a mechanical
# single-anchor add, take ONLY the model's "+" lines per file and splice them at a known anchor:
#   vouchers.ts      -> before the LAST "];" (close of VOUCHERS)
#   vouchers.test.ts -> before the closing "});" of describe(... "effective caps" ...)
# Still exactly ONE model call; never deletes existing lines.
if [ "$APPLIED" != true ]; then
  add_note "git apply failed for all strategies; trying deterministic anchor-insert"
  if python3 - "$DIFF_FILE" "$VOUCHERS" "$VTEST" <<'PY'
import sys
diff_path, vouchers_path, vtest_path = sys.argv[1:4]
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
v_add = next((v for k, v in added.items() if k.endswith('vouchers.ts')), [])
vt_add = next((v for k, v in added.items() if 'vouchers.test.ts' in k), [])
if not v_add or not any('fortune_scale' in x for x in v_add):
    sys.stderr.write("fallback: no fortune_scale added-lines for vouchers.ts\n"); ok = False
else:
    src = open(vouchers_path).read().splitlines()
    idx = max(i for i, s in enumerate(src) if s.strip() == '];')
    open(vouchers_path, 'w').write("\n".join(src[:idx] + v_add + src[idx:]) + "\n")
if not vt_add or not any('fortune_scale' in x for x in vt_add):
    sys.stderr.write("fallback: no fortune_scale added-lines for vouchers.test.ts\n"); ok = False
else:
    src = open(vtest_path).read().splitlines()
    di = next((i for i, s in enumerate(src) if 'effective caps' in s and 'describe(' in s), None)
    if di is None:
        sys.stderr.write("fallback: effective-caps describe not found\n"); ok = False
    else:
        depth = 0; close = None
        for i in range(di, len(src)):
            depth += src[i].count('{') - src[i].count('}')
            if i > di and depth <= 0: close = i; break
        if close is None:
            sys.stderr.write("fallback: describe close not found\n"); ok = False
        else:
            open(vtest_path, 'w').write("\n".join(src[:close] + vt_add + src[close:]) + "\n")
sys.exit(0 if ok else 1)
PY
  then APPLIED=true; APPLY_METHOD="deterministic anchor-insert"; add_note "applied with: $APPLY_METHOD"; fi
fi
if [ "$APPLIED" != true ]; then
  add_note "all apply strategies failed (incl. anchor-insert)"
  err "----- model diff that failed to apply -----"; cat "$DIFF_FILE" >&2; err "-------------------------------------------"
  emit false none none none
fi

# (5) guard, then bun install + bun test
APPLIED_DIFF="$WORKDIR/applied.diff"; git -C "$CLONE" diff >"$APPLIED_DIFF"
GUARD_RESULT="skipped"
if [ -n "$GUARD" ] && [ -f "$GUARD" ]; then
  bash "$GUARD" "$APPLIED_DIFF" >"$WORKDIR/guard.out" 2>"$WORKDIR/guard.err"; GRC=$?
  if [ "$GRC" -eq 0 ]; then GUARD_RESULT="ok"; elif [ "$GRC" -eq 2 ]; then GUARD_RESULT="blocked"; else GUARD_RESULT="error"; fi
  add_note "guard exit $GRC ($GUARD_RESULT)"
else add_note "guard script not found; skipped"; fi
TESTS="none"; err "bun install + bun test..."
if (cd "$CLONE" && bun install >/dev/null 2>&1); then
  (cd "$CLONE" && bun test src/engine/vouchers.test.ts) >"$WORKDIR/test.out" 2>&1; TRC=$?
  PASS="$(grep -Eo '[0-9]+ pass' "$WORKDIR/test.out" | tail -1)"
  FAILN="$(grep -Eo '[0-9]+ fail' "$WORKDIR/test.out" | tail -1)"
  [ "$TRC" -eq 0 ] && TESTS="pass" || TESTS="fail"
  add_note "voucher tests: ${PASS:-?}, ${FAILN:-?} (rc=$TRC)"
else add_note "bun install failed"; TESTS="none"; fi
emit "$APPLIED" "$APPLY_METHOD" "$GUARD_RESULT" "$TESTS"
