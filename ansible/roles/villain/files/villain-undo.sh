#!/bin/sh
# villain-undo <vmid>: put one Lab Villains decoy back. Safe to run twice.
# Refuses any container whose hostname is not decoy-<group>-<vmid>, so a typo cannot start or
# touch a real guest. Installed by roles/villain; the dead-man timer and the undo play both run it.
set -eu
vmid="${1:?usage: villain-undo <vmid>}"
case "$vmid" in *[!0-9]*) echo "villain-undo: REFUSED: vmid must be digits" >&2; exit 2 ;; esac
if ! pct config "$vmid" | grep -Eq "^hostname: decoy-(dc|marvel)-${vmid}$"; then
  echo "villain-undo: REFUSED: $vmid is not a decoy" >&2
  exit 2
fi
if ! pct status "$vmid" | grep -q "status: running"; then
  pct start "$vmid"
  sleep 5
fi
pct exec "$vmid" -- systemctl start ssh
pct exec "$vmid" -- systemctl is-active ssh
echo "$(date -Is) undo $vmid ok" >> /var/log/villain.log
