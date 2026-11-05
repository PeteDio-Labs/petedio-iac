#!/usr/bin/env bash
# lab-updates — read-only report of OS patch state for every Proxmox node and LXC.
#
#   ./scripts/lab-updates.sh          # run from claude-247 or the Mac (needs ssh to pve02 and pve03)
#
# Changes nothing: it runs no `apt-get update`, no upgrade and no reboot. It reads the apt
# lists each host already holds, so it prints each list's age. A count from a stale list
# undercounts, and the age line is how you tell.
#
# Covers the three nodes (pve02, pve03, pve01 at 192.168.50.12), every running LXC on them,
# the ollama-246 VM on pve01 (no pct; read over ssh) and pi1. A guest that is not running is
# not examined and is not counted.
#
# Reports what it examined. "0 upgradable across 0 guests" must not look like
# "0 upgradable across 20 guests", so the last line names the counts and the names of
# every unreadable host, and the script exits non-zero when any node or guest could not be
# read. A host with no security suite in its apt sources is its own state (nosec): its
# security=0 proves nothing, so the report prints security=n/a for it and the last line
# names it. That state does not change the exit code (PET-828 owns the fix).
set -uo pipefail

PVE02=pve02
PVE03=pve03
# The former ollama-host, a node since PET-528. Reached by address with the Ansible key,
# not by alias: an ssh config written before 2026-09-03 may still map `pve01` to .10, which
# is pve03 now (same rule as lab-verify.sh).
PVE01=root@192.168.50.12
OLLAMA246=root@192.168.50.246
PI=pi1
KEY="$HOME/.ssh/id_ed25519_ansible"
EXAMINED=0; UNREADABLE=0; PENDING=0; REBOOT=0; NOSEC=0
UNREADABLE_NAMES=""; NOSEC_NAMES=""

# The ${o[@]+...} form keeps bash 3.2, the Mac's, from failing on an empty array under -u.
on() {
  local o=()
  case "$1" in "$PVE01"|"$OLLAMA246") o=(-i "$KEY");; esac
  ssh -n -o ConnectTimeout=8 -o BatchMode=yes ${o[@]+"${o[@]}"} "$1" "$2" 2>/dev/null
}
# pve03 is an unprivileged login, so pct needs sudo there (lab-verify.sh does the same).
pct_on() {  # node, args...
  local n=$1; shift
  if [ "$n" = "$PVE03" ]; then on "$n" "sudo /usr/sbin/pct $*"; else on "$n" "pct $*"; fi
}

# One probe, run inside the host or guest. Prints: os|upgradable|security|list_age_days|reboot|unattended|secsuite
# secsuite is yes when an apt source names a *security* suite, no when none does.
# It prints "ERR <reason>" and exits 1 when it cannot read the patch state, so a failed
# apt simulation never turns into a "0 upgradable" row.
PROBE='
. /etc/os-release
command -v apt-get >/dev/null 2>&1 || { echo "ERR no-apt-get (${PRETTY_NAME:-unknown os})"; exit 1; }
sim=$(apt-get -s dist-upgrade 2>&1) || { echo "ERR apt-simulation"; exit 1; }
up=$(printf "%s\n" "$sim" | grep -c "^Inst ")
sec=$(printf "%s\n" "$sim" | grep "^Inst " | grep -ci "security")
newest=$(stat -c %Y /var/lib/apt/periodic/update-success-stamp /var/lib/apt/lists 2>/dev/null | sort -n | tail -1)
[ -n "$newest" ] || { echo "ERR apt-list-age"; exit 1; }
age=$(( ( $(date +%s) - newest ) / 86400 ))
rb=no; [ -e /var/run/reboot-required ] && rb=yes
ua=no; dpkg -s unattended-upgrades >/dev/null 2>&1 && ua=yes
ss=no; cat /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null | grep -Eiv "^[[:space:]]*#" | grep -Eiq "^(deb[[:space:]]|Suites:).*security" && ss=yes
echo "$PRETTY_NAME|$up|$sec|$age|$rb|$ua|$ss"
'
KERNEL_Q="dpkg-query -W -f '\${Package}\n' 'proxmox-kernel-*-pve-signed' 2>/dev/null | sort -V | tail -1"

unreadable() {  # label, reason
  UNREADABLE=$((UNREADABLE+1)); UNREADABLE_NAMES="$UNREADABLE_NAMES ${1// /_}"
  printf "  ✗ %-28s unreadable: %s\n" "$1" "$2"
}

report() {  # label, raw probe output, optional diagnosis command (prints why when the probe gave nothing)
  local label=$1 raw=$2 diag=${3:-} last why
  last=$(printf '%s' "$raw" | tail -1)
  if ! printf '%s' "$last" | grep -Eq '^[^|]+\|[0-9]+\|[0-9]+\|[0-9]+\|(yes|no)\|(yes|no)\|(yes|no)$'; then
    case "$last" in
      "ERR "*) why="${last#ERR }" ;;
      "")      why="probe printed nothing (ssh or exec failed, or the guest has no sh)"
               [ -n "$diag" ] && why="$why; guest says: $(eval "$diag" | head -1)" ;;
      *)       why="unexpected probe output: $(printf '%s' "$last" | cut -c1-80)" ;;
    esac
    unreadable "$label" "$why"; return
  fi
  IFS='|' read -r os up sec age rb ua ss <<<"$last"
  EXAMINED=$((EXAMINED+1)); PENDING=$((PENDING+up))
  [ "$rb" = yes ] && REBOOT=$((REBOOT+1))
  if [ "$ss" = no ]; then
    NOSEC=$((NOSEC+1)); NOSEC_NAMES="$NOSEC_NAMES ${label// /_}"; sec="n/a"
  fi
  printf "  %s %-28s %-26s upgradable=%-3s security=%-3s lists=%sd old reboot=%s unattended=%s%s\n" \
    "$([ "$up" -gt 0 ] && echo '!' || echo '✓')" "$label" "$os" "$up" "$sec" "$age" "$rb" "$ua" \
    "$([ "$ss" = no ] && echo '  [nosec: no security suite in apt sources]')"
}

for n in $PVE02 $PVE03 $PVE01; do
  nl=$n; [ "$n" = "$PVE01" ] && nl=pve01
  printf "\n%s\n" "== node $nl"
  pv=$(on "$n" "pveversion" | head -1)
  run=$(on "$n" "uname -r"); inst=$(on "$n" "$KERNEL_Q")
  if [ -z "$pv" ] || [ -z "$run" ] || [ -z "$inst" ]; then
    unreadable "$nl (node info)" "could not read pveversion or kernel (pve='${pv:-?}' running='${run:-?}' installed='${inst:-?}')"
  else
    echo "  $pv | running kernel $run | newest installed $inst"
  fi
  report "$nl (host)" "$(on "$n" "$PROBE")"
  # Keep the listing's exit status apart from its content: a node with no running guests is healthy.
  if ! listing=$(pct_on "$n" list) || [ -z "$listing" ]; then
    unreadable "$nl (pct list)" "pct list failed"; continue
  fi
  ids=$(printf '%s\n' "$listing" | awk 'NR>1 && $2=="running"{print $1}')
  [ -z "$ids" ] && echo "  (no running guests on $nl)"
  for id in $ids; do
    name=$(pct_on "$n" "exec $id -- hostname")
    report "$id ${name:-?}" "$(pct_on "$n" "exec $id -- sh -c '$PROBE'")" \
      "pct_on $n \"exec $id -- sh -c 'head -1 /etc/os-release; command -v apt-get || echo no apt-get'\""
  done
done

# Not LXC: a VM on pve01 and a Pi. Neither has pct, so the same probe runs over ssh.
printf "\n%s\n" "== VM and bare metal (read over ssh)"
report "246 ollama-246 (VM)" "$(on "$OLLAMA246" "sh -c '$PROBE'")"
report "pi1" "$(on "$PI" "sh -c '$PROBE'")"

printf "\nexamined %d hosts or guests; %d unreadable%s; %d packages upgradable; %d need a reboot; %d with no security suite%s\n" \
  "$EXAMINED" "$UNREADABLE" "${UNREADABLE_NAMES:+ (${UNREADABLE_NAMES# })}" "$PENDING" "$REBOOT" \
  "$NOSEC" "${NOSEC_NAMES:+ (${NOSEC_NAMES# })}"
[ "$UNREADABLE" -eq 0 ] && [ "$EXAMINED" -gt 0 ]
