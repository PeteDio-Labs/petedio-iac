#!/usr/bin/env bash
# hdd-burnin.sh — burn in new HDDs before they join a ZFS pool (MED-6, phase 1 of
# docs/runbooks/three-machine-split.md).
#
# Runs on the node that holds the drives (pve-media). It DESTROYS ALL DATA on every
# drive you name. Each drive gets: SMART before, a short test, a long test, one
# badblocks write pass, a second long test, SMART after. Drives run in parallel and
# take 2-4 days for 16 TB, so start it under tmux or systemd-run.
#
#   scripts/hdd-burnin.sh plan   <by-id path>...    # print what would run; changes nothing
#   scripts/hdd-burnin.sh run    <by-id path>...    # needs BURNIN_CONFIRM=<serial list>
#   scripts/hdd-burnin.sh report <by-id path>...    # verdict from the saved logs
#
# A drive passes only if all of these hold:
#   * badblocks found 0 bad blocks,
#   * both long SMART tests finished "Completed without error",
#   * reallocated (5), pending (197) and offline-uncorrectable (198) sectors are 0
#     after the run, and none of 5, 187, 188, 197, 198 rose from the baseline.
# `report` exits 1 on any failure, any missing log, and when given no drives. It prints
# how many drives it examined, so "0 failed of 4" cannot be mistaken for "0 failed of 0".
#
# Environment:
#   BURNIN_LOG_DIR   where logs go (default /var/log/hdd-burnin)
#   BURNIN_CONFIRM   run only: the serial numbers of the drives, sorted, joined by commas.
#                    `plan` prints the exact value. This stops a mistyped path from
#                    wiping a pool member.
set -euo pipefail

LOG_DIR="${BURNIN_LOG_DIR:-/var/log/hdd-burnin}"
WATCH_ATTRS="5 187 188 197 198"

die(){ printf 'ABORT: %s\n' "$*" >&2; exit 1; }
usage(){ sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2; exit 2; }

need(){ command -v "$1" >/dev/null || die "$1 not in PATH"; }

# smartctl prints "Serial Number:    XYZ". Empty output is a fault, not a blank serial.
serial_of(){
  local s
  s="$(smartctl -i "$1" | awk -F: '/^Serial [Nn]umber/ {gsub(/^[ \t]+/,"",$2); print $2; exit}')"
  [ -n "$s" ] || die "no serial number from smartctl for $1"
  printf '%s' "$s"
}

# Name used for log files: the by-id basename, so a log maps to one physical drive.
tag_of(){ basename "$1"; }

# Raw value of one SMART attribute, or "NA" when the drive does not report it.
attr_raw(){
  smartctl -A "$1" | awk -v id="$2" '$1==id {print $10; found=1; exit} END {if(!found) print "NA"}'
}

check_target(){
  local dev="$1"
  case "$dev" in
    /dev/disk/by-id/*) ;;
    *) die "$dev: pass a /dev/disk/by-id path, not a /dev/sdX name that can change between boots" ;;
  esac
  [ -b "$dev" ] || die "$dev: not a block device"
  local real; real="$(readlink -f "$dev")"
  # Refuse anything mounted, partitioned, carrying a filesystem or a ZFS label.
  if lsblk -nr -o MOUNTPOINTS "$real" | grep -q '[^[:space:]]'; then
    die "$dev ($real) or a partition of it is mounted"
  fi
  if [ -n "$(wipefs -n "$real" 2>/dev/null)" ]; then
    die "$dev ($real) has a signature (wipefs -n lists it). Wipe it on purpose first; this script does not."
  fi
  if command -v zpool >/dev/null && zpool status -P 2>/dev/null | grep -qF "$real"; then
    die "$dev ($real) is in an imported ZFS pool"
  fi
}

confirm_value(){
  local d out=()
  for d in "$@"; do out+=("$(serial_of "$d")"); done
  printf '%s\n' "${out[@]}" | sort | paste -sd, -
}

burn_one(){
  local dev="$1" tag; tag="$(tag_of "$1")"
  local log="$LOG_DIR/$tag"
  mkdir -p "$log"
  : > "$log/status"
  {
    echo "serial=$(serial_of "$dev")"
    for a in $WATCH_ATTRS; do echo "before_$a=$(attr_raw "$dev" "$a")"; done
  } > "$log/baseline.txt"
  smartctl -x "$dev" > "$log/smart-before.txt" || true   # smartctl sets nonzero bits for warnings

  smart_test "$dev" short "$log"
  smart_test "$dev" long "$log" long1
  echo "badblocks: start $(date -Is)" >> "$log/status"
  # -w destructive write, -b 4096 and -c 65535 to keep it fast on 16 TB, -s progress, -v verbose.
  # stdout lists bad blocks; the exit code alone is not trusted.
  badblocks -wsv -b 4096 -c 65535 -o "$log/badblocks.txt" "$dev" > "$log/badblocks.progress" 2>&1 \
    || echo "badblocks: exit nonzero" >> "$log/status"
  echo "badblocks: end $(date -Is)" >> "$log/status"
  smart_test "$dev" long "$log" long2
  smartctl -x "$dev" > "$log/smart-after.txt" || true
  for a in $WATCH_ATTRS; do echo "after_$a=$(attr_raw "$dev" "$a")"; done >> "$log/baseline.txt"
  echo "done $(date -Is)" >> "$log/status"
}

# Start a SMART self-test and poll until it is no longer in progress. The result is
# read from the self-test log, never assumed.
smart_test(){
  local dev="$1" kind="$2" log="$3" label="${4:-$2}"
  echo "smart $label: start $(date -Is)" >> "$log/status"
  smartctl -t "$kind" "$dev" > "$log/smart-$label-start.txt" || die "smartctl -t $kind failed on $dev"
  sleep 60
  while smartctl -c "$dev" | grep -q 'Self-test routine in progress'; do sleep 300; done
  smartctl -l selftest "$dev" > "$log/smart-$label-result.txt" || true
  echo "smart $label: end $(date -Is)" >> "$log/status"
}

verdict_one(){
  local dev="$1" tag log; tag="$(tag_of "$1")"; log="$LOG_DIR/$tag"
  local fails=() f
  for f in baseline.txt status smart-long1-result.txt smart-long2-result.txt; do
    [ -s "$log/$f" ] || fails+=("missing or empty log $f")
  done
  # An empty badblocks.txt is the pass case, so only its absence is a fault.
  [ -e "$log/badblocks.txt" ] || fails+=("missing log badblocks.txt")
  if [ ${#fails[@]} -eq 0 ]; then
    grep -q '^done ' "$log/status" || fails+=("run did not finish")
    grep -q 'badblocks: exit nonzero' "$log/status" && fails+=("badblocks exited nonzero")
    [ -s "$log/badblocks.txt" ] && fails+=("badblocks found $(wc -l < "$log/badblocks.txt") bad blocks")
    local n
    for n in 1 2; do
      # The newest self-test is the first numbered line of the log.
      awk '/^# *1 /' "$log/smart-long$n-result.txt" | grep -q 'Completed without error' \
        || fails+=("long test $n did not complete without error")
    done
    local a b af
    for a in $WATCH_ATTRS; do
      b="$(sed -n "s/^before_$a=//p" "$log/baseline.txt")"
      af="$(sed -n "s/^after_$a=//p" "$log/baseline.txt")"
      [ -n "$af" ] || { fails+=("no after value for attribute $a"); continue; }
      [ "$af" = NA ] && continue
      case "$a" in 5|197|198) [ "$af" = 0 ] || fails+=("attribute $a is $af, expected 0") ;; esac
      [ "$b" = NA ] || [ "$af" -le "$b" ] || fails+=("attribute $a rose from $b to $af")
    done
  fi
  if [ ${#fails[@]} -eq 0 ]; then
    printf 'PASS  %s  serial %s\n' "$tag" "$(sed -n 's/^serial=//p' "$log/baseline.txt")"
    return 0
  fi
  printf 'FAIL  %s\n' "$tag"
  printf '        - %s\n' "${fails[@]}"
  return 1
}

cmd="${1:-}"; [ -n "$cmd" ] || usage; shift || true
case "$cmd" in
  plan|run|report) ;;
  *) usage ;;
esac
[ $# -gt 0 ] || die "no drives given; pass at least one /dev/disk/by-id path"

case "$cmd" in
  plan|run)
    for t in smartctl badblocks lsblk wipefs; do need "$t"; done
    for d in "$@"; do check_target "$d"; done
    want="$(confirm_value "$@")"
    echo "Drives to erase and burn in ($#):"
    for d in "$@"; do echo "  $d  serial $(serial_of "$d")  -> $(readlink -f "$d")"; done
    echo "Logs: $LOG_DIR/<by-id name>/"
    echo "BURNIN_CONFIRM=$want"
    [ "$cmd" = plan ] && { echo "plan only: nothing changed."; exit 0; }
    [ "${BURNIN_CONFIRM:-}" = "$want" ] \
      || die "BURNIN_CONFIRM does not match. Check the serials above, then set BURNIN_CONFIRM=$want"
    pids=()
    for d in "$@"; do burn_one "$d" & pids+=($!); done
    rc=0
    for p in "${pids[@]}"; do wait "$p" || rc=1; done
    [ $rc -eq 0 ] || die "a burn-in process failed; run: $0 report $*"
    echo "Finished $# drives. Run: $0 report $*"
    ;;
  report)
    fail=0; n=0
    for d in "$@"; do n=$((n+1)); verdict_one "$d" || fail=$((fail+1)); done
    echo "examined $n drives: $((n-fail)) passed, $fail failed"
    [ $fail -eq 0 ]
    ;;
esac
