#!/bin/sh
# security-patch.sh — install pending security updates inside one guest, and never reboot (PET-908).
# patch-guests.yml pipes it into `pct exec <vmid> -- sh -s <mode>`; the 247 or Mac host step for
# pi1 pipes it over ssh (docs/runbooks/upgrades.md).
#
#   sh -s plan    # read-only: simulate, change nothing
#   sh -s apply   # apt-get update, then upgrade the security packages that are not held
#
# A package whose upgrade restarts a service the lab depends on is HELD, not upgraded. It is
# reported in the count, and its own runbook upgrades it with a check first (Vault needs an unseal;
# Docker restarts every container). Change the hold list here, in one place.
#
# The last line is always `RESULT|<mode>|<os>|security=N|held=N|patched=N|remaining=N|reboot=<yes|no>|lists=<days>`,
# so a caller never reads "0 pending" out of a command that failed. It exits non-zero when apt
# fails, and prints no package name, because the run log is public.
set -eu

MODE=${1:-}
case "$MODE" in plan|apply) ;; *) echo "REFUSED: mode must be plan or apply" >&2; exit 2 ;; esac

. /etc/os-release
OSNAME=${PRETTY_NAME:-unknown}
if command -v apk >/dev/null 2>&1; then
  # apk marks no update as a security fix, so this script cannot tell which ones to take.
  echo "RESULT|$MODE|$OSNAME|security=na|held=0|patched=0|remaining=na|reboot=no|lists=na"
  exit 0
fi

HOLD='^(vault|postgresql|docker|containerd|runc|nvidia|libnvidia|plexmediaserver|minio|grafana|loki|prometheus|alloy|tailscale|cloudflared|linux-image|linux-modules|proxmox|pve-|libpve|qemu|lxc|corosync|zfs)'
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l NEEDRESTART_SUSPEND=1

# Block every maintainer-script service restart during an apply. A package list alone cannot
# stop `libssl3` or `libc6` from restarting Vault, Postgres or dockerd through its postinst, so
# policy-rc.d answers 101 ("do not start or restart") and is removed afterwards. A patched library
# stays loaded by a running service until that service restarts, so `reboot=` and the runbook say
# when to restart one deliberately.
PRC=/usr/sbin/policy-rc.d
if [ "$MODE" = apply ]; then
  [ ! -e "$PRC" ] || { echo "ERR $PRC already exists" >&2; exit 1; }
  printf '#!/bin/sh\nexit 101\n' > "$PRC"; chmod 755 "$PRC"
  trap 'rm -f "$PRC"' EXIT
fi

if [ "$MODE" = apply ]; then
  apt-get update -q >/dev/null 2>&1 || { echo "ERR apt-get update failed" >&2; exit 1; }
fi

# Names of every `Inst` line whose origin is a security pocket (Debian-Security, noble-security).
pending() {
  sim=$(apt-get -s dist-upgrade 2>/dev/null) || return 1
  printf '%s\n' "$sim" | awk '/^Inst / && tolower($0) ~ /security/ {print $2}'
}
all=$(pending) || { echo "ERR apt simulation failed" >&2; exit 1; }
take=$(printf '%s\n' "$all" | grep -Ev "$HOLD" | grep -v '^$' || true)
held=$(printf '%s\n' "$all" | grep -E "$HOLD" | grep -vc '^$' || true)
sec=$(printf '%s\n' "$all" | grep -vc '^$' || true)
patched=0

if [ "$MODE" = apply ] && [ -n "$take" ]; then
  # shellcheck disable=SC2086 # package names never hold whitespace
  apt-get install -y -q --only-upgrade --no-install-recommends \
    -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef $take >/dev/null 2>&1 \
    || { echo "ERR apt-get install failed" >&2; exit 1; }
  patched=$(printf '%s\n' "$take" | grep -vc '^$')
fi

after=$(pending) || { echo "ERR apt simulation failed" >&2; exit 1; }
remaining=$(printf '%s\n' "$after" | grep -Ev "$HOLD" | grep -vc '^$' || true)
newest=$(stat -c %Y /var/lib/apt/periodic/update-success-stamp /var/lib/apt/lists 2>/dev/null | sort -n | tail -1)
[ -n "$newest" ] || { echo "ERR package-list-age" >&2; exit 1; }
lists=$(( ( $(date +%s) - newest ) / 86400 ))
rb=no; [ -e /var/run/reboot-required ] && rb=yes
echo "RESULT|$MODE|$OSNAME|security=$sec|held=$held|patched=$patched|remaining=$remaining|reboot=$rb|lists=$lists"
