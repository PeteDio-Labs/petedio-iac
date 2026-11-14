#!/bin/sh
# staging-power (node side) — the one command the `staging-power` SSH certificate may run on pve03.
#
# The Vault SSH role fixes this script as the certificate's command (vault-config/staging-power.tf),
# so the caller's own command arrives in SSH_ORIGINAL_COMMAND. Only three words pass: status,
# start and stop. They act on container 249 and nothing else, and only while that container is
# still named staging-249, so a reused VMID is never touched.
#
# Every success prints one line that starts with `staging-249:`, and every refusal exits non-zero.
set -eu

VMID=249
NAME=staging-249
cmd="${SSH_ORIGINAL_COMMAND:-}"

case "$cmd" in
  status | start | stop) ;;
  *) echo "staging-power: refused '$cmd'. Only status, start and stop are allowed." >&2; exit 2 ;;
esac

if ! pct config "$VMID" 2>/dev/null | grep -qx "hostname: $NAME"; then
  echo "staging-power: container $VMID is not named $NAME on this node." >&2
  exit 3
fi

state() { pct status "$VMID" | sed 's/^status: //'; }

now=$(state)
case "$cmd" in
  status) ;;
  start) if [ "$now" != running ]; then pct start "$VMID"; fi ;;
  stop) if [ "$now" = running ]; then pct shutdown "$VMID" --timeout 90; fi ;;
esac
echo "$NAME: $(state)"
