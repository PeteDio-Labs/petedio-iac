#!/usr/bin/env bash
# reviewer-stamp-pedro-verdict.sh — stamp Pedro's merge/kickback verdict onto an EXISTING
# row of the JSONL eval log in MinIO (PET-191).
#
# The gap this closes: `reviewer-log-verdict.sh` writes the reviewer's row with
# `pedro_verdict` left "" — the runbook says Pedro's verdict is "appended on merge/kickback",
# but nothing ever wrote it, so `pedro_verdict` is empty in every row. The eval set needs
# that label to measure reviewer precision/recall vs Pedro. This script supplies it: it finds
# the matching row (by PET key, and PR when given) and writes `pedro_verdict` in place.
#
# This is the human-decision half — Pedro runs it after he merges or kicks back a worker PR.
# A merge-triggered GitHub Action was rejected on purpose: (a) worker PRs live in the
# Co-latro app repos, not here, so an Action would have to be duplicated into each; (b) a
# merge event can only ever record `merge`, never `kickback` (a closed-unmerged PR); (c) the
# whole eval log is a single-operator, serial-writer object (no lock) — an operator-run
# script keeps that invariant. So this mirrors `reviewer-log-verdict.sh` exactly instead.
#
# Object stores can't edit in place, so this does download -> rewrite the matching line ->
# upload via `mc`, the same read-modify-write the append path uses. ONE serial writer, no
# lock (same single-operator assumption as the TF state backend); if that changes this races.
#
# SECRETS: none here. `mc` reads its credentials from a preconfigured alias (`mc alias set`),
# which Pedro seeds from Vault `kv/services/agent-loop` (mc_access_key / mc_secret_key) — path
# reference only, never embedded. See docs/runbooks/reviewer-loop.md.
#
# Usage:
#   scripts/reviewer/reviewer-stamp-pedro-verdict.sh \
#     --issue PET-42 --verdict merge|kickback [--pr 17] \
#     [--allow-overwrite]    # re-stamp a row that already has a pedro_verdict
#     [--dry-run]            # print the would-be row, do NOT upload (no mc needed)
#
# Matching: rows are matched on `issue` (== --issue) AND, when --pr is given, `pr` (== --pr).
# If more than one row matches (e.g. several review round-trips for one PET key) the script
# refuses and asks for --pr to disambiguate — it never guesses which row is "the" verdict.
#
# Env (optional):
#   REVIEWER_MC_ALIAS       mc alias for the homelab MinIO (default: homelab)
#   REVIEWER_VERDICTS_PATH  bucket/key for the log (default: agent-evals/verdicts.jsonl)
set -euo pipefail

die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

ISSUE="" VERDICT="" PR="" ALLOW_OVERWRITE=false DRY_RUN=false

while [ $# -gt 0 ]; do
  case "$1" in
    --issue) ISSUE="$2"; shift 2 ;;
    --verdict) VERDICT="$2"; shift 2 ;;
    --pr) PR="$2"; shift 2 ;;
    --allow-overwrite) ALLOW_OVERWRITE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h | --help) sed -n '2,40p' "$0"; exit 0 ;;
    *) die "unknown arg: $1 (see --help)" ;;
  esac
done

command -v python3 >/dev/null || die "python3 not in PATH (jq isn't on the loop host)."

# --- validate up front (a bad label silently corrupts the eval set) ---
[ -n "$ISSUE" ] || die "--issue is required (e.g. PET-42)."
case "$VERDICT" in merge | kickback) ;; *) die "--verdict must be merge|kickback (got '$VERDICT')." ;; esac
[ -z "$PR" ] || [[ "$PR" =~ ^[0-9]+$ ]] || die "--pr must be an integer if set (got '$PR')."

ALIAS="${REVIEWER_MC_ALIAS:-homelab}"
VPATH="${REVIEWER_VERDICTS_PATH:-agent-evals/verdicts.jsonl}"
TARGET="${ALIAS}/${VPATH}"

command -v mc >/dev/null || die "mc not in PATH (install via roles/agent-loop, agent_loop_install_mc)."
mc alias list "$ALIAS" >/dev/null 2>&1 ||
  die "mc alias '$ALIAS' not configured. Seed it from Vault kv/services/agent-loop (see docs/runbooks/reviewer-loop.md)."

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

mc stat "$TARGET" >/dev/null 2>&1 || die "$TARGET does not exist — nothing to stamp (run the reviewer first)."
mc cat "$TARGET" >"$TMP" 2>/dev/null || die "could not read existing $TARGET."

# Rewrite the matching line(s) with python so JSON parsing + escaping stay correct, and so
# we can refuse ambiguous / already-stamped rows rather than clobber the wrong label.
NEW="$(
  ISSUE="$ISSUE" VERDICT="$VERDICT" PR="$PR" ALLOW_OVERWRITE="$ALLOW_OVERWRITE" \
  python3 - "$TMP" <<'PY'
import json, os, sys

path = sys.argv[1]
issue = os.environ["ISSUE"]
verdict = os.environ["VERDICT"]
pr = os.environ["PR"]
allow_overwrite = os.environ["ALLOW_OVERWRITE"] == "true"

with open(path, encoding="utf-8") as f:
    raw_lines = f.read().splitlines()

rows = []          # (index, parsed-dict) for non-blank lines
out = list(raw_lines)
for i, line in enumerate(raw_lines):
    if not line.strip():
        continue
    try:
        rows.append((i, json.loads(line)))
    except json.JSONDecodeError as e:
        sys.exit(f"line {i+1} of the log is not valid JSON: {e}")

def matches(row):
    if row.get("issue") != issue:
        return False
    if pr != "":
        # `pr` is stored as a string by the reviewer and as an int/None by the worker log;
        # compare as strings so "17" and 17 both match.
        return str(row.get("pr")) == str(pr)
    return True

hits = [(i, r) for (i, r) in rows if matches(r)]
if not hits:
    where = f"issue={issue}" + (f", pr={pr}" if pr else "")
    sys.exit(f"no row matches {where}. Pass --pr to widen/narrow the match, or check the issue key.")
if len(hits) > 1 and pr == "":
    prs = ", ".join(sorted({str(r.get('pr')) for _, r in hits}))
    sys.exit(f"{len(hits)} rows match issue={issue} (PRs: {prs}). Pass --pr <n> to pick one.")
if len(hits) > 1:
    sys.exit(f"{len(hits)} rows match issue={issue}, pr={pr} — refusing to stamp an ambiguous match.")

i, row = hits[0]
existing = row.get("pedro_verdict", "")
if existing and not allow_overwrite:
    if existing == verdict:
        sys.exit(f"row already has pedro_verdict={existing} (nothing to do).")
    sys.exit(f"row already has pedro_verdict={existing}; pass --allow-overwrite to change it to {verdict}.")

row["pedro_verdict"] = verdict
out[i] = json.dumps(row, separators=(",", ":"), ensure_ascii=False)
sys.stdout.write("\n".join(l for l in out if l.strip() != "") + "\n")
PY
)" || exit 1

if [ "$DRY_RUN" = true ]; then
  printf '%s' "$NEW"
  exit 0
fi

printf '%s' "$NEW" | mc pipe "$TARGET" >/dev/null 2>&1 ||
  die "upload to $TARGET failed (bucket exists? alias creds valid?)."
printf '\033[1;32mstamped pedro_verdict=%s for %s%s in %s\033[0m\n' \
  "$VERDICT" "$ISSUE" "$([ -n "$PR" ] && echo " (PR $PR)")" "$TARGET" >&2
