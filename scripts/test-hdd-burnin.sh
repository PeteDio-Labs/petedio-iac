#!/usr/bin/env bash
# test-hdd-burnin.sh — offline checks for scripts/hdd-burnin.sh `report` and its refusals.
# No drive is touched: it builds synthetic logs. Exits 1 on the first wrong verdict.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$here/hdd-burnin.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export BURNIN_LOG_DIR="$T"

mk(){ # name  badblocks-lines  long2-result  after5
  local d="$T/$1"; mkdir -p "$d"
  printf 'serial=S-%s\n' "$1" > "$d/baseline.txt"
  for a in 5 187 188 197 198; do echo "before_$a=0" >> "$d/baseline.txt"; done
  for a in 187 188 197 198; do echo "after_$a=0" >> "$d/baseline.txt"; done
  echo "after_5=$4" >> "$d/baseline.txt"
  printf 'done\n' > "$d/status"; sed -i 's/^done$/done 2026-01-01/' "$d/status"
  : > "$d/badblocks.txt"; [ "$2" -gt 0 ] && seq "$2" > "$d/badblocks.txt"
  echo '# 1  Extended offline    Completed without error       00%   100         -' > "$d/smart-long1-result.txt"
  echo "# 1  Extended offline    $3       00%   100         -" > "$d/smart-long2-result.txt"
}
expect(){ # want-rc label args...
  local want="$1" label="$2"; shift 2
  local rc=0; out="$("$S" "$@" 2>&1)" || rc=$?
  [ "$rc" -eq "$want" ] || { echo "FAIL $label: exit $rc, want $want"; echo "$out"; exit 1; }
  echo "ok   $label"
}

mk good 0 "Completed without error" 0
mk badblk 3 "Completed without error" 0
mk badtest 0 "Completed: read failure" 0
mk realloc 0 "Completed without error" 8
mkdir -p "$T/empty"
D=/dev/disk/by-id
expect 0 "good drive passes"          report "$D/good"
expect 1 "bad blocks fail"            report "$D/badblk"
expect 1 "failed long test fails"     report "$D/badtest"
expect 1 "reallocated sectors fail"   report "$D/realloc"
expect 1 "missing logs fail"          report "$D/empty"
expect 1 "one bad of two fails"       report "$D/good" "$D/badblk"
expect 1 "no drives is a fault"       report
expect 2 "unknown command is usage"   frobnicate
echo "$("$S" report "$D/good" "$D/badblk" 2>&1 | tail -1)" | grep -q 'examined 2 drives: 1 passed, 1 failed' \
  || { echo "FAIL summary line"; exit 1; }
echo "ok   summary names how many drives it read"
echo "all hdd-burnin checks passed"
