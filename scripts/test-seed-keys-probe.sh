#!/usr/bin/env bash
# test-seed-keys-probe.sh: drive the probe() function of seed-keys-cloudflare.sh against a fake
# Cloudflare answer for each verdict. No network, no credentials. Runs in keys-check.yml.
#
# The probe guards a credential write, so every answer it does not recognize must stop the
# script (.claude/rules/scripts.md). jq gives length 0 for null, {} and "", so those cases are
# here on purpose (Codex review of petedio-iac#694).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FN="$(sed -n '/^probe() {/,/^}/p' "$HERE/seed-keys-cloudflare.sh")"
[ -n "$FN" ] || { echo "test-seed-keys-probe: no probe() in seed-keys-cloudflare.sh"; exit 2; }

pass=0 fail=0 n=0
check() {  # <want: pass|stop> <http code> <body>
  n=$((n + 1))
  got=stop
  if out="$(CODE="$2" BODY="$3" FN="$FN" bash -c '
    TMP="$(mktemp -d)"; CF_API=fake
    die() { echo "DIE: $*"; exit 1; }
    cf_get() { printf "%s" "$BODY" > "$3"; echo "$CODE"; }
    eval "$FN"
    probe tunnels /x' 2>&1)"; then
    got=pass
  fi
  if [ "$got" = "$1" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: HTTP $2 $3 -> $got, want $1: $out"; fi
}

check pass 200 '{"result":[]}'
check stop 200 '{"result":[{"id":"t"}]}'
check pass 403 '{}'
check pass 400 '{}'
check stop 500 '{}'
check stop 200 'not json'
check stop 200 '{}'
check stop 200 '{"result":null}'
check stop 200 '{"result":{}}'
check stop 200 '{"result":""}'

echo "test-seed-keys-probe: $pass of $n cases passed"
[ "$fail" = 0 ] && [ "$n" -gt 0 ]
