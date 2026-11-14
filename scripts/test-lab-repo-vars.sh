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

printf '%d passed, %d failed\n' "$PASS" "$FAIL"; [ "$FAIL" = 0 ]
