#!/usr/bin/env bash
# fleet-scorecard.sh — turn the agent-evals JSONL into per-agent pass-rates (PET-184 gap).
#
# The eval of the first full three-agent cycle flagged: raw run/verdict logs exist, but there is
# no aggregate — no per-agent PASS/FAIL rate, no sample size (n), nothing to drive the S0→S1
# autonomy decision. This reads the three logs from MinIO (worker-runs / engine-runs / verdicts)
# and computes, per agent: run count, tests/gate green-rate, reviewer approve-rate, and Pedro
# merge-rate (joining verdicts to runs on issue+pr). READ-ONLY — never writes.
#
# Usage:  scripts/fleet-scorecard.sh [--json] [--since YYYY-MM-DD]
# Env:    FLEET_MC_ALIAS (default homelab), FLEET_EVALS_PREFIX (default agent-evals).
#         Or FLEET_LOCAL_DIR=<dir> to read worker-runs/engine-runs/verdicts.jsonl from disk.
set -uo pipefail
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

JSON=false SINCE=""
while [ $# -gt 0 ]; do case "$1" in
  --json) JSON=true; shift ;;
  --since) SINCE="$2"; shift 2 ;;
  -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
  *) die "unknown arg: $1" ;;
esac; done

ALIAS="${FLEET_MC_ALIAS:-homelab}"; PREFIX="${FLEET_EVALS_PREFIX:-agent-evals}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
for f in worker-runs engine-runs verdicts; do
  if [ -n "${FLEET_LOCAL_DIR:-}" ]; then
    cp "${FLEET_LOCAL_DIR}/$f.jsonl" "$TMP/$f.jsonl" 2>/dev/null || : >"$TMP/$f.jsonl"
  else
    command -v mc >/dev/null || die "mc not in PATH (or set FLEET_LOCAL_DIR)."
    mc cat "$ALIAS/$PREFIX/$f.jsonl" >"$TMP/$f.jsonl" 2>/dev/null || : >"$TMP/$f.jsonl"
  fi
done

TMP="$TMP" JSON="$JSON" SINCE="$SINCE" python3 <<'PY'
import json, os
tmp, want_json, since = os.environ["TMP"], os.environ["JSON"] == "true", os.environ["SINCE"]
def load(f):
    rows = []
    try:
        for line in open(f"{tmp}/{f}.jsonl"):
            line = line.strip()
            if not line: continue
            try: r = json.loads(line)
            except Exception: continue
            if since and str(r.get("ts","")) < since: continue
            rows.append(r)
    except OSError: pass
    return rows
worker, engine, verd = load("worker-runs"), load("engine-runs"), load("verdicts")

def pct(n, d): return f"{100*n/d:.0f}%" if d else "—"
def key(r): return (str(r.get("issue","")), str(r.get("pr")))

# index verdicts by (issue, pr) for author-level join
vmap = {}
for v in verd: vmap[key(v)] = v

def agent_stats(runs, greenfield):
    n = len(runs)
    green = sum(1 for r in runs if str(r.get(greenfield)) in ("pass","green"))
    approved = merged = reviewed = 0
    for r in runs:
        v = vmap.get(key(r))
        if not v: continue
        reviewed += 1
        if str(v.get("claude_verdict")) == "approve": approved += 1
        if str(v.get("pedro_verdict")) == "merge": merged += 1
    return dict(n=n, green=green, greenrate=pct(green,n), reviewed=reviewed,
               approverate=pct(approved,reviewed), merged=merged, mergerate=pct(merged,n))

ws = agent_stats(worker, "tests")   # worker: tests pass
es = agent_stats(engine, "guard")   # engine: gate green (stored in `guard`)
# reviewer: over all verdicts
vn = len(verd); vappr = sum(1 for v in verd if str(v.get("claude_verdict"))=="approve")
vmerge = sum(1 for v in verd if str(v.get("pedro_verdict"))=="merge")
rt = [int(v.get("round_trips",0) or 0) for v in verd]

if want_json:
    print(json.dumps({"worker": ws, "engine": es,
        "reviewer": {"verdicts": vn, "approve_rate": pct(vappr,vn), "merge_rate": pct(vmerge,vn),
                     "avg_round_trips": round(sum(rt)/len(rt),2) if rt else 0}}, separators=(",",":")))
else:
    print("=== Fleet scorecard" + (f" (since {since})" if since else "") + " ===")
    print(f"WORKER    n={ws['n']:<3} tests-green {ws['greenrate']:<4}  reviewer-approve {ws['approverate']:<4}  merged {ws['mergerate']}")
    print(f"ENGINE    n={es['n']:<3} gate-green  {es['greenrate']:<4}  reviewer-approve {es['approverate']:<4}  merged {es['mergerate']}")
    print(f"REVIEWER  verdicts={vn:<3} approve {pct(vappr,vn):<4}  pedro-merge {pct(vmerge,vn):<4}  avg round-trips {round(sum(rt)/len(rt),2) if rt else 0}")
    tot = ws['n']+es['n']
    print(f"OVERALL   author runs={tot}  merged={ws['merged']+es['merged']}  cycle sample n={tot}")
PY
