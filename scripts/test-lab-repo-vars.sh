#!/usr/bin/env bash
# Tests for scripts/lab-repo-vars.py and the lab-action.sh routing of repo_vars and health (PET-884).
set -uo pipefail
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
check(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$3" "$2"; fi; }
AL="$(mktemp)"; trap 'rm -f "$AL"' EXIT
printf 'ALLOW_DESTROY\nMANAGE_BACKUP_JOB # note\n' > "$AL"

OUT="$(REPO_VARS_JSON='{"ALLOW_DESTROY":"true","SECRET_THING":"nope"}' python3 scripts/lab-repo-vars.py "$AL")"; RC=$?
check "exit 0 on a valid read" "$RC" 0
check "prints a set name" "$(grep -c '^ALLOW_DESTROY = true$' <<<"$OUT")" 1
check "prints an unset name" "$(grep -c '^MANAGE_BACKUP_JOB is unset$' <<<"$OUT")" 1
check "never prints a name outside the allowlist" "$(grep -c 'SECRET_THING\|nope' <<<"$OUT")" 0
check "summary says what was examined" "$(grep -c '^probe repo_vars: examined 2 allowlisted names of 2 variables held, 1 set$' <<<"$OUT")" 1

REPO_VARS_JSON='' python3 scripts/lab-repo-vars.py "$AL" >/dev/null 2>&1; check "empty input fails" "$?" 1
REPO_VARS_JSON='[1]' python3 scripts/lab-repo-vars.py "$AL" >/dev/null 2>&1; check "non-object input fails" "$?" 1
REPO_VARS_JSON='{}' python3 scripts/lab-repo-vars.py "$AL" >/dev/null 2>&1; check "no variables held is a valid, counted read" "$?" 0
: > "$AL"; REPO_VARS_JSON='{}' python3 scripts/lab-repo-vars.py "$AL" >/dev/null 2>&1; check "empty allowlist fails" "$?" 1

OUT="$(REPO_VARS_JSON='{"ALLOW_DESTROY":"true"}' scripts/lab-action.sh repo_vars 2>&1)"; check "lab-action.sh routes repo_vars with no Vault" "$(grep -c '^ALLOW_DESTROY = true$' <<<"$OUT")" 1
scripts/lab-action.sh lab_probe bogus "" >/dev/null 2>&1; check "unknown probe refused" "$?" 2
check "health is an allowlisted probe" "$(grep -c 'media_ask|guests|health' scripts/lab-action.sh | awk '{print ($1>0)}')" 1
check "backup_jobs is an allowlisted probe" "$(grep -cF 'backup_jobs|ollama_ps|prometheus)$' scripts/lab-action.sh | awk '{print ($1>0)}')" 1
check "ollama_ps is an allowlisted probe" "$(grep -cF '|ollama_ps|prometheus)$' scripts/lab-action.sh | awk '{print ($1>0)}')" 1
check "prometheus is an allowlisted probe" "$(grep -cF '|ollama_ps|prometheus)$' scripts/lab-action.sh | awk '{print ($1>0)}')" 1
bash -n scripts/lab-probe.sh; check "lab-probe.sh parses" "$?" 0

# The prometheus probe's remote program, run against a fake Prometheus on a free port (no lab contact).
PD="$(mktemp -d)"; trap 'rm -f "$AL"; rm -rf "$PD"; [ -z "${FPID:-}" ] || kill "$FPID" 2>/dev/null' EXIT
cat > "$PD/srv.py" <<'PYEOF'
import http.server, json, sys, urllib.parse
MODE = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(s):
        p = urllib.parse.urlparse(s.path).path
        if MODE == "down" and p == "/api/v1/query":
            s.send_response(500); s.end_headers(); return
        d = {"/api/v1/query": {"result": [{"metric": {}}]}, "/api/v1/rules": {"groups": []},
             "/api/v1/alerts": {"alerts": []},
             "/api/v1/targets": {"activeTargets": [] if MODE == "notargets" else [{"health": "up"}]}}[p]
        s.send_response(200); s.end_headers(); s.wfile.write(json.dumps({"status": "success", "data": d}).encode())
    def log_message(*a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PYEOF
PORT=$((20000 + RANDOM % 20000))
PROG="$(python3 -c "
import re,sys
s=open('scripts/lab-probe.sh').read()
print(re.search(r\"REMOTE_PROM='(.*?)'\\nif \\[\", s, re.S).group(1).replace('127.0.0.1:9090','127.0.0.1:$PORT').replace('/etc/metric-alerts/rules.json','$PD/rules.json'))
")"
runprom(){ # mode rules-json
  python3 "$PD/srv.py" "$PORT" "$1" & FPID=$!; sleep 1
  printf '%s' "$2" > "$PD/rules.json"
  OUTP="$(python3 -c "$PROG" 2>&1)"; RCP=$?
  kill "$FPID" 2>/dev/null; wait "$FPID" 2>/dev/null; FPID=""
}
R='[{"name":"zpool-not-online","expr":"x","for_runs":1}]'
runprom ok "$R"; check "prometheus probe: good read exits 0" "$RCP" 0
check "prometheus probe: names the rule" "$(grep -c '^metric-alerts rule zpool-not-online: in rules.json, for_runs=1, 1 series now$' <<<"$OUTP")" 1
check "prometheus probe: summary says what was examined" "$(grep -c '^probe prometheus: read 1 metric-alerts rules .*1 of 1 targets up$' <<<"$OUTP")" 1
runprom ok '[]'; check "prometheus probe: empty rules file fails" "$RCP" 1
runprom ok 'not json'; check "prometheus probe: unparseable rules file fails" "$RCP" 1
runprom notargets "$R"; check "prometheus probe: zero targets fails" "$RCP" 1
runprom down "$R"; check "prometheus probe: a failing query fails" "$RCP" 1

printf '%d passed, %d failed\n' "$PASS" "$FAIL"; [ "$FAIL" = 0 ]
