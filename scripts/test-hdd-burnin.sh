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
# Inspection failures must refuse, not pass as "nothing found". Stub the three readers.
( # shellcheck source=/dev/null
  source "$S"
  try(){ ( inspect_target /dev/disk/by-id/ata-X /dev/sdz ) >/dev/null 2>&1; }
  lsblk(){ return 0; }; wipefs(){ return 0; }; zpool(){ return 0; }
  try || { echo "FAIL clean drive refused"; exit 1; }; echo "ok   clean drive is accepted"
  wipefs(){ echo "ext4 signature" ; }; try && { echo "FAIL signature accepted"; exit 1; }; echo "ok   signature is refused"
  wipefs(){ return 1; }; try && { echo "FAIL wipefs error accepted"; exit 1; }; echo "ok   wipefs error is refused"
  wipefs(){ return 0; }; lsblk(){ return 1; }; try && { echo "FAIL lsblk error accepted"; exit 1; }; echo "ok   lsblk error is refused"
  lsblk(){ echo /mnt/x; }; try && { echo "FAIL mounted accepted"; exit 1; }; echo "ok   mounted drive is refused"
  lsblk(){ return 0; }; zpool(){ return 1; }; try && { echo "FAIL zpool error accepted"; exit 1; }; echo "ok   zpool error is refused"
  zpool(){ echo "  /dev/disk/by-id/ata-X ONLINE"; }; try && { echo "FAIL pooled accepted"; exit 1; }; echo "ok   pool member is refused"
)
# SMART read and serial failures must abort, not yield a blank serial or an "NA" pass.
( source "$S"
  smartctl(){ return 2; }
  serial_of /dev/x >/dev/null 2>&1 && { echo "FAIL serial read failure accepted"; exit 1; }; echo "ok   failed serial read is refused"
  confirm_value /dev/x >/dev/null 2>&1 && { echo "FAIL confirm_value accepted a failed serial"; exit 1; }; echo "ok   failed serial cannot yield an empty confirmation"
  attr_raw /dev/x 5 >/dev/null 2>&1 && { echo "FAIL attr read failure accepted"; exit 1; }; echo "ok   failed attribute read is refused"
  smartctl(){ echo "Serial Number:    ABC123"; return 0; }
  [ "$(serial_of /dev/x)" = ABC123 ] || { echo "FAIL serial parse"; exit 1; }; echo "ok   serial parses"
  smartctl(){ printf '  5 Reallocated_Sector_Ct 0x0033 100 100 010 Pre-fail Always - 0\n'; return 8; }
  [ "$(attr_raw /dev/x 5)" = 0 ] || { echo "FAIL attr parse"; exit 1; }; echo "ok   a health-bit exit status is not a read failure"
  [ "$(attr_raw /dev/x 187)" = NA ] || { echo "FAIL NA"; exit 1; }; echo "ok   unsupported attribute reads NA"
)
echo "$("$S" report "$D/good" "$D/badblk" 2>&1 | tail -1)" | grep -q 'examined 2 drives: 1 passed, 1 failed' \
  || { echo "FAIL summary line"; exit 1; }
echo "ok   summary names how many drives it read"
echo "all hdd-burnin checks passed"
