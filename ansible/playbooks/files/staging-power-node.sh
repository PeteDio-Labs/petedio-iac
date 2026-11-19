#!/bin/sh
# staging-power (node side) — the one command the `staging-power` SSH certificate may run on pve03.
#
# The Vault SSH role fixes this script as the certificate's command (vault-config/staging-power.tf),
# so the caller's own command arrives in SSH_ORIGINAL_COMMAND. Only five words pass: status,
# clock, start, stop and teardown. They act on container 249 and nothing else, and only while that container is
# still named staging-249, so a reused VMID is never touched.
#
# Every success prints one line that starts with `staging-249:`, and every refusal exits non-zero.
set -eu

VMID=249
NAME=staging-249
cmd="${SSH_ORIGINAL_COMMAND:-}"

case "$cmd" in
  status | clock | start | stop | teardown) ;;
  *) echo "staging-power: refused '$cmd'. Only status, clock, start, stop and teardown are allowed." >&2; exit 2 ;;
esac

if ! pct config "$VMID" 2>/dev/null | grep -qx "hostname: $NAME"; then
  echo "staging-power: container $VMID is not named $NAME on this node." >&2
  exit 3
fi

state() { pct status "$VMID" | sed 's/^status: //'; }

# systemd forgets a stopped unit's timestamps once it unloads the unit, so the stop time also lives
# in a file here. `start` removes it, and `stop`, `teardown` and a `clock` that finds no other
# record write it. A file that is missing for a stopped box is filled with the time of this look,
# so a push that arrived earlier never counts as newer than the shutdown.
STOPPED=/var/lib/staging-power/stopped-$VMID
mark_stopped() { mkdir -p "$(dirname "$STOPPED")" && date +%s > "$STOPPED"; }

now=$(state)
case "$cmd" in
  status) ;;
  # When the container last started (while running) or last stopped (while stopped), as epoch
  # seconds, or 0 when running with no start time. A stopped box always reports a time: systemd's,
  # else the recorded file, else now. staging-power.py enforces the 24 h limit and the restart
  # rule from this one number.
  clock)
    prop=InactiveEnterTimestamp
    [ "$now" = running ] && prop=ActiveEnterTimestamp
    ts=$(systemctl show "pve-container@$VMID" -p "$prop" --value 2>/dev/null || true)
    epoch=0
    if [ -n "$ts" ]; then epoch=$(date -d "$ts" +%s 2>/dev/null || echo 0); fi
    if [ "$now" = running ]; then
      rm -f "$STOPPED"
    else
      if [ "$epoch" -gt 0 ]; then
        mkdir -p "$(dirname "$STOPPED")" && echo "$epoch" > "$STOPPED"
      elif [ -s "$STOPPED" ]; then
        epoch=$(cat "$STOPPED")
      else
        mark_stopped
        epoch=$(cat "$STOPPED")
      fi
    fi
    echo "$NAME: $now $epoch"
    exit 0 ;;
  start) if [ "$now" != running ]; then pct start "$VMID"; fi; rm -f "$STOPPED" ;;
  stop) if [ "$now" = running ]; then pct shutdown "$VMID" --timeout 90; mark_stopped; fi ;;
  # A promoted site: both sites go back to their placeholder page, then the box stops. A box that
  # is already stopped is left alone, because reaching its files would mean starting it.
  teardown)
    if [ "$now" = running ]; then
      pct exec "$VMID" -- /usr/local/sbin/staging-reset
      pct shutdown "$VMID" --timeout 90
      mark_stopped
    fi ;;
esac
echo "$NAME: $(state)"
