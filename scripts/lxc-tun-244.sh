#!/usr/bin/env bash
# lxc-tun-244.sh — give the tailscale LXC 244 a /dev/net/tun device out-of-band, on
# the Proxmox node, over SSH-as-root. (PET-188)
#
# WHY THIS ISN'T TERRAFORM / AN API TOKEN:
#   A Tailscale subnet router routes real packets through a TUN interface, so the LXC
#   needs /dev/net/tun. Adding a device to an unprivileged LXC hits the same hardcoded
#   `user == root@pam` check that blocks the features{} mutation (docs/GOTCHAS.md): an
#   API token is `root@pam!tokenid`, not `root@pam`, so it fails. bpg/proxmox creates
#   the LXC WITHOUT the device (device_passthrough is in the module's ignore_changes),
#   and this script adds it the only way that works: `pct set` as root@pam on the node.
#   Without /dev/net/tun, `tailscale up` fails with "CreateTUN ... operation not permitted".
#
# SAFE: touches ONLY container 244, and only reboots 244 (empty until the
# configure-tailscale rollout). Idempotent — if dev0 is already the tun device it makes
# no change and does NOT reboot.
#
#   pve host:  $PVE_HOST  (default 192.168.50.10 = pve01, where 244 lives)
#   pve key :  $PVE_SSH_KEY (default ~/.ssh/id_ed25519_proxmox_pedro — bare-metal root)
#   lxc key :  $LXC_SSH_KEY (default ~/.ssh/id_ed25519_ansible — the key TF installs in 244)
# NB: the Proxmox NODE and the LXC use DIFFERENT keys — the node is bare metal (root via
# the proxmox key), 244 is a TF-created LXC (root via the ansible key). Don't conflate them.
set -euo pipefail

PVE_HOST="${PVE_HOST:-192.168.50.10}"
PVE_SSH_USER="${PVE_SSH_USER:-root}"
VMID="${VMID:-244}"
LXC_IP="${LXC_IP:-192.168.50.244}"
PVE_SSH_KEY="${PVE_SSH_KEY:-$HOME/.ssh/id_ed25519_proxmox_pedro}"
LXC_SSH_KEY="${LXC_SSH_KEY:-$HOME/.ssh/id_ed25519_ansible}"

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }
command -v ssh >/dev/null || die "ssh not in PATH"
[ -f "$PVE_SSH_KEY" ] || die "Proxmox SSH key not found: $PVE_SSH_KEY"
[ -f "$LXC_SSH_KEY" ] || die "LXC SSH key not found: $LXC_SSH_KEY"

SSH=(ssh -i "$PVE_SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$PVE_SSH_USER@$PVE_HOST")

step "Reading current device config of LXC $VMID on $PVE_HOST"
CFG="$("${SSH[@]}" "pct config $VMID" 2>/dev/null)" || die "cannot read pct config $VMID on $PVE_HOST (is $VMID on this node? is SSH-as-root working?)"
CUR_DEV0="$(printf '%s\n' "$CFG" | sed -nE 's/^dev0:[[:space:]]*//p')"
echo "  current: dev0: ${CUR_DEV0:-<none>}"

if printf '%s' "$CUR_DEV0" | grep -q '/dev/net/tun'; then
  step "Already set (dev0 -> /dev/net/tun) — no change, no reboot."
  exit 0
fi

step "Adding /dev/net/tun to LXC $VMID (dev0, mode=0666)"
"${SSH[@]}" "pct set $VMID -dev0 /dev/net/tun,mode=0666" || die "pct set dev0 failed."

step "Rebooting LXC $VMID so the device appears (244 is empty — safe)"
"${SSH[@]}" "pct reboot $VMID" || {
  echo "  pct reboot did not complete cleanly; falling back to stop/start"
  "${SSH[@]}" "pct stop $VMID || true; sleep 3; pct start $VMID"
}

step "Waiting for $VMID to answer SSH on $LXC_IP (LXC key, not the pve key)"
for i in $(seq 1 30); do
  if ssh -i "$LXC_SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
        "root@$LXC_IP" true 2>/dev/null; then
    echo "  up after ${i} tries"; break
  fi
  [ "$i" = 30 ] && die "container $VMID did not come back on $LXC_IP after the reboot."
  sleep 4
done

step "Confirming the device is present inside the container"
"${SSH[@]}" "pct exec $VMID -- test -c /dev/net/tun" \
  || die "/dev/net/tun not present inside $VMID after set — inspect manually."

step "Done — LXC $VMID has /dev/net/tun; tailscaled can create its TUN interface."
echo "Next: run ansible/playbooks/configure-tailscale.yml (see roles/tailscale-router/README.md)."
