#!/bin/sh
# Tests the node command's stop-time record with a fake pct, systemctl and state directory.
# Run: sh scripts/test-staging-power-node.sh
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
# Rewrite the record path into the temp dir; everything else runs as shipped.
sed "s#/var/lib/staging-power#$tmp/state#" "$here/ansible/playbooks/files/staging-power-node.sh" > "$tmp/node.sh"
cat > "$tmp/bin/pct" <<'F'
#!/bin/sh
case "$1" in
  config) echo "hostname: staging-249" ;;
  status) echo "status: $(cat "$FAKE/pctstate")" ;;
  shutdown) echo stopped > "$FAKE/pctstate" ;;
  start) echo running > "$FAKE/pctstate" ;;
esac
F
cat > "$tmp/bin/systemctl" <<'F'
#!/bin/sh
cat "$FAKE/ts" 2>/dev/null || true
F
chmod +x "$tmp/bin/pct" "$tmp/bin/systemctl"
export FAKE="$tmp" PATH="$tmp/bin:$PATH"
run() { SSH_ORIGINAL_COMMAND=$1 sh "$tmp/node.sh"; }
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2', want '$3'"; fail=1; fi; }

echo running > "$tmp/pctstate"; echo "Thu 2026-11-19 01:00:00 UTC" > "$tmp/ts"
out=$(run clock); case "$out" in "staging-249: running "[1-9]*) r=ok ;; *) r="$out" ;; esac
check "running clock has a start time" "$r" ok

run stop >/dev/null
check "stop writes the record" "$([ -s "$tmp/state/stopped-249" ] && echo yes)" yes
: > "$tmp/ts"   # systemd forgot the unit
recorded=$(cat "$tmp/state/stopped-249")
out=$(run clock)
check "stopped clock reads the record when systemd has none" "$out" "staging-249: stopped $recorded"

rm -f "$tmp/state/stopped-249"
out=$(run clock); got=${out##* }
check "stopped with no record at all still reports a time" "$([ "$got" -gt 0 ] && echo yes)" yes

run start >/dev/null
check "start removes the record" "$([ -e "$tmp/state/stopped-249" ] && echo kept || echo gone)" gone
echo "examined 5 cells"
exit $fail
