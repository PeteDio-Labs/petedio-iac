#!/usr/bin/env bash
# lab-updates — read-only report of OS patch state for every Proxmox node, LXC and the Pi.
#
#   ./scripts/lab-updates.sh          # run from claude-247 or the Mac (needs ssh to pve01, pve02, pve03 and pi1)
#
# Changes nothing: it runs no `apt-get update`, no upgrade and no reboot. It reads the apt
# lists each host already holds, so it prints each list's age. A count from a stale list
# undercounts, and the age line is how you tell.
#
# Reports what it examined. "0 upgradable across 0 guests" must not look like
# "0 upgradable across 20 guests", so the last line names both counts and the
# script exits non-zero when any node or guest could not be read.
set -uo pipefail

PVE01=root@192.168.50.12   # the former ollama-host, a node since PET-528; reached by address, like lab-verify.sh
PVE02=pve02
PVE03=pve03
PI=pi1
EXAMINED=0; SKIPPED=0; UNREADABLE=0; PENDING=0; REBOOT=0

on() { local o=(); [ "$1" = "$PVE01" ] && o=(-i "$HOME/.ssh/id_ed25519_ansible")
       ssh -n -o ConnectTimeout=8 -o BatchMode=yes ${o[@]+"${o[@]}"} "$1" "$2" 2>/dev/null; }
# pve03 is an unprivileged login, so pct needs sudo there (lab-verify.sh does the same).
pct_on() {  # node, args...
  local n=$1; shift
  if [ "$n" = "$PVE03" ]; then on "$n" "sudo /usr/sbin/pct $*"; else on "$n" "pct $*"; fi
}

# One probe, run inside the host or guest. Prints: os|upgradable|security|list_age_days|reboot|unattended
# It prints "ERR <reason>" and exits 1 when it cannot read the patch state, so a failed
# apt simulation never turns into a "0 upgradable" row.
PROBE='
. /etc/os-release
sim=$(apt-get -s dist-upgrade 2>&1) || { echo "ERR apt-simulation"; exit 1; }
up=$(printf "%s\n" "$sim" | grep -c "^Inst ")
sec=$(printf "%s\n" "$sim" | grep "^Inst " | grep -ci "security")
newest=$(stat -c %Y /var/lib/apt/periodic/update-success-stamp /var/lib/apt/lists 2>/dev/null | sort -n | tail -1)
[ -n "$newest" ] || { echo "ERR apt-list-age"; exit 1; }
age=$(( ( $(date +%s) - newest ) / 86400 ))
rb=no; [ -e /var/run/reboot-required ] && rb=yes
ua=no; dpkg -s unattended-upgrades >/dev/null 2>&1 && ua=yes
echo "$PRETTY_NAME|$up|$sec|$age|$rb|$ua"
'
KERNEL_Q="dpkg-query -W -f '\${Package}\n' 'proxmox-kernel-*-pve-signed' 2>/dev/null | sort -V | tail -1"

report() {  # label, raw probe output
  local label=$1 raw=$2
  if ! printf '%s' "$raw" | tail -1 | grep -Eq '^[^|]+\|[0-9]+\|[0-9]+\|[0-9]+\|(yes|no)\|(yes|no)$'; then
    UNREADABLE=$((UNREADABLE+1)); printf "  ✗ %-28s unreadable\n" "$label"; return
  fi
  IFS='|' read -r os up sec age rb ua <<<"$(printf '%s' "$raw" | tail -1)"
  EXAMINED=$((EXAMINED+1)); PENDING=$((PENDING+up))
  [ "$rb" = yes ] && REBOOT=$((REBOOT+1))
  printf "  %s %-28s %-26s upgradable=%-3s security=%-3s lists=%sd old reboot=%s unattended=%s\n" \
    "$([ "$up" -gt 0 ] && echo '!' || echo '✓')" "$label" "$os" "$up" "$sec" "$age" "$rb" "$ua"
}

for n in $PVE01 $PVE02 $PVE03; do
  printf "\n%s\n" "== node $n"
  pv=$(on "$n" "pveversion" | head -1)
  run=$(on "$n" "uname -r"); inst=$(on "$n" "$KERNEL_Q")
  if [ -z "$pv" ] || [ -z "$run" ] || [ -z "$inst" ]; then
    UNREADABLE=$((UNREADABLE+1)); echo "  ✗ $n: could not read pveversion or kernel (pve='${pv:-?}' running='${run:-?}' installed='${inst:-?}')"
  else
    echo "  $pv | running kernel $run | newest installed $inst"
  fi
  report "$n (host)" "$(on "$n" "$PROBE")"
  # Keep the listing's exit status apart from its content: a node with no running guests is healthy.
  if ! listing=$(pct_on "$n" list) || [ -z "$listing" ]; then
    UNREADABLE=$((UNREADABLE+1)); echo "  ✗ $n: pct list failed"; continue
  fi
  ids=$(printf '%s\n' "$listing" | awk 'NR>1 && $2=="running"{print $1}')
  [ -z "$ids" ] && echo "  (no running guests on $n)"
  for id in $ids; do
    name=$(pct_on "$n" "exec $id -- hostname")
    report "$id ${name:-?}" "$(pct_on "$n" "exec $id -- sh -c '$PROBE'")"
  done
done

printf "\n== bare metal %s\n" "$PI"
# lab-action runs on runner 232, which holds no key for the Pi (lab-verify.sh skips it for the
# same reason). Count the skip, so the last line never looks like full coverage.
if [ "${LAB_ACTION:-}" = 1 ]; then
  SKIPPED=$((SKIPPED+1)); echo "  - $PI (host)                   skipped: no key on the lab-action runner (PET-849)"
else
  report "$PI (host)" "$(on "$PI" "$PROBE")"
fi
printf "\nexamined %d hosts or guests; %d unreadable; %d skipped; %d packages upgradable; %d need a reboot\n" \
  "$EXAMINED" "$UNREADABLE" "$SKIPPED" "$PENDING" "$REBOOT"
[ "$UNREADABLE" -eq 0 ] && [ "$EXAMINED" -gt 0 ]
