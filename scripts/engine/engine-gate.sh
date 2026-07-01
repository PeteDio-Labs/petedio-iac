#!/usr/bin/env bash
# engine-gate.sh — the engine's "can't finish red" gate (PET-184, Phase 0b).
#
# The engine (Claude Code, Sonnet-tier, PET-184) authors a NEW effect `kind` + handler +
# a tested exemplar entry. Unlike the worker's additive-only guard, the engine writes real
# logic, so the gate is a full correctness pass, run in THREE stages:
#
#   1. typecheck   — `bun run typecheck` (tsc --noEmit): never let a non-compiling tree be
#                    called "done" (the 0e checkpoint rule — WIP commits must compile).
#   2. tests       — `bun test`: the whole suite (unit + the fast-check property files).
#   3. property    — re-run ONLY src/engine/**/*.property.test.ts with hardened run counts
#                    (ENGINE_GATE=1) — the never-throws / output-shape / determinism /
#                    round-trip / additive-invariance invariants the engine's PRs MUST keep
#                    green. This stage is the `additive-guard` signal for Phase-3 auto-merge.
#
# TWO CALLERS, one script:
#   * As a Claude Code **Stop hook** (docs/runbooks/engine-loop.md wires it into the run-scoped
#     ~/.claude/settings.json): a RED gate exits **2**, which blocks the engine from ending its
#     turn and feeds the failing stage back to it to fix. A GREEN gate exits 0 (turn may end).
#   * As the harness's **independent verification** (engine-run.sh re-runs it as ground truth
#     before pushing — never trust the agent's own "it's green"): non-zero == red.
#
# Operates on $1 (repo dir) or $PWD. If the dir has no package.json / no `test` script it is
# NOT a gate-able repo — exit 0 (a Stop hook in an unrelated repo must be a no-op, never block).
#
# Output: a one-line JSON verdict on stdout {"gate","typecheck","tests","property","dir"};
# human-readable stage lines on stderr. Exit 0 = green, 2 = red, other = harness/tooling error.
set -uo pipefail

note() { printf '\033[1;34m%s\033[0m\n' "$*" >&2; }
red()  { printf '\033[1;31m%s\033[0m\n' "$*" >&2; }
grn()  { printf '\033[1;32m%s\033[0m\n' "$*" >&2; }

DIR="${1:-$PWD}"
cd "$DIR" 2>/dev/null || { red "engine-gate: cannot cd into '$DIR'"; exit 1; }

emit_verdict() { # $1 gate  $2 typecheck  $3 tests  $4 property
  printf '{"gate":"%s","typecheck":"%s","tests":"%s","property":"%s","dir":"%s"}\n' \
    "$1" "$2" "$3" "$4" "$DIR"
}

# Not a gate-able JS/TS repo → no-op success (harmless Stop hook elsewhere).
if [ ! -f package.json ] || ! grep -q '"test"' package.json 2>/dev/null; then
  note "engine-gate: no package.json/test script in $DIR — nothing to gate (no-op)."
  emit_verdict skip skip skip skip
  exit 0
fi

command -v bun >/dev/null 2>&1 || { red "engine-gate: bun not in PATH."; exit 1; }

# node_modules may be absent on a fresh clone / first Stop; install once (quiet, best-effort).
if [ ! -d node_modules ]; then
  note "engine-gate: installing deps (bun install)…"
  bun install >/dev/null 2>&1 || { red "engine-gate: bun install failed."; exit 1; }
fi

LOG="$(mktemp "${TMPDIR:-/tmp}/engine-gate-XXXXXX.log")"
trap 'rm -f "$LOG"' EXIT

TYPECHECK=fail TESTS=fail PROPERTY=fail

# --- stage 1: typecheck -----------------------------------------------------------------
note "engine-gate [1/3] typecheck (tsc --noEmit)…"
if grep -q '"typecheck"' package.json 2>/dev/null; then TC_CMD=(bun run typecheck); else TC_CMD=(bun x tsc --noEmit); fi
if "${TC_CMD[@]}" >"$LOG" 2>&1; then
  TYPECHECK=pass; grn "engine-gate [1/3] typecheck: PASS"
else
  red "engine-gate [1/3] typecheck: FAIL"; tail -n 30 "$LOG" >&2
  emit_verdict red fail skipped skipped
  exit 2
fi

# --- stage 2: full test suite (unit + property) -----------------------------------------
note "engine-gate [2/3] tests (bun test)…"
if bun test >"$LOG" 2>&1; then
  TESTS=pass; grn "engine-gate [2/3] tests: PASS"
else
  red "engine-gate [2/3] tests: FAIL"; tail -n 40 "$LOG" >&2
  emit_verdict red pass fail skipped
  exit 2
fi

# --- stage 3: hardened property re-run (the additive-guard signal) ----------------------
# Re-run only the fast-check property files with ENGINE_GATE=1 so those files may bump their
# numRuns for a harder pass. Skippable (ENGINE_GATE_SKIP_PROPERTY_HARDEN=1) for a fast local
# check; the engine harness always runs it.
if [ "${ENGINE_GATE_SKIP_PROPERTY_HARDEN:-0}" = 1 ]; then
  PROPERTY=skipped; note "engine-gate [3/3] property-harden: SKIPPED (env)."
else
  # Collect property files (portable; no `git` dependency so the Stop hook works pre-commit).
  PROP_FILES=()
  while IFS= read -r f; do PROP_FILES+=("$f"); done < <(find src -type f -name '*.property.test.ts' 2>/dev/null | sort)
  if [ "${#PROP_FILES[@]}" -eq 0 ]; then
    PROPERTY=none; note "engine-gate [3/3] property-harden: no *.property.test.ts found (none)."
  else
    note "engine-gate [3/3] property-harden (${#PROP_FILES[@]} file(s), ENGINE_GATE=1)…"
    if ENGINE_GATE=1 bun test "${PROP_FILES[@]}" >"$LOG" 2>&1; then
      PROPERTY=pass; grn "engine-gate [3/3] property-harden: PASS"
    else
      red "engine-gate [3/3] property-harden: FAIL"; tail -n 40 "$LOG" >&2
      emit_verdict red pass pass fail
      exit 2
    fi
  fi
fi

grn "engine-gate: GREEN (typecheck=$TYPECHECK tests=$TESTS property=$PROPERTY)"
emit_verdict green "$TYPECHECK" "$TESTS" "$PROPERTY"
exit 0
