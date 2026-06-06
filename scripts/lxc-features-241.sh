#!/usr/bin/env bash
# lxc-features-241.sh — set the container `features` (nesting + keyctl) on the
# openfaas LXC 241 out-of-band, on the Proxmox node, over SSH-as-root. (PET-86)
#
# WHY THIS ISN'T TERRAFORM / AN API TOKEN:
#   Proxmox enforces a hardcoded `user == root@pam` check for the LXC features{}
#   mutation. An API token's username is `root@pam!tokenid`, not `root@pam`, so it
#   fails — even for a PVEAdmin token (docs/GOTCHAS.md). So bpg/proxmox creates the
#   LXC WITHOUT a features{} block (kept in ignore_changes), and this script applies
#   nesting=1,keyctl=1 the only way that works: `pct set` as root@pam on the node.
#   containerd/faasd inside the unprivileged LXC will not start containers without them.
#
# NB (faasd): if faasd's CNI bridge can't come up (function networking), the LXC may
# also need a tun device — uncomment the TUN line below and re-run, then reboot.
#
# SAFE: it touches ONLY container 241, and only reboots 241 (which is empty until
# the configure-openfaas rollout). Idempotent — if the features are already present
# it makes no change and does NOT reboot.
#
#   pve host:  $PVE_HOST  (default 192.168.50.10 = pve01, where 241 lives)
#   pve key :  $PVE_SSH_KEY (default ~/.ssh/id_ed25519_proxmox_pedro — bare-metal root)
#   lxc key :  $LXC_SSH_KEY (default ~/.ssh/id_ed25519_ansible — the key TF installs in 241)
# NB: the Proxmox NODE and the LXC use DIFFERENT keys — the node is bare metal (root via
# the proxmox key), 241 is a TF-created LXC (root via the ansible key). Don't conflate them.
set -euo pipefail

PVE_HOST="${PVE_HOST:-192.168.50.10}"
PVE_SSH_USER="${PVE_SSH_USER:-root}"
VMID="${VMID:-241}"
LXC_IP="${LXC_IP:-192.168.50.241}"
PVE_SSH_KEY="${PVE_SSH_KEY:-$HOME/.ssh/id_ed25519_proxmox_pedro}"
LXC_SSH_KEY="${LXC_SSH_KEY:-$HOME/.ssh/id_ed25519_ansible}"
FEATURES="nesting=1,keyctl=1"

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }
command -v ssh >/dev/null || die "ssh not in PATH"
[ -f "$PVE_SSH_KEY" ] || die "Proxmox SSH key not found: $PVE_SSH_KEY"
[ -f "$LXC_SSH_KEY" ] || die "LXC SSH key not found: $LXC_SSH_KEY"

SSH=(ssh -i "$PVE_SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$PVE_SSH_USER@$PVE_HOST")

step "Reading current features of LXC $VMID on $PVE_HOST"
CFG="$("${SSH[@]}" "pct config $VMID" 2>/dev/null)" || die "cannot read pct config $VMID on $PVE_HOST (is $VMID on this node? is SSH-as-root working?)"
CUR_FEATURES="$(printf '%s\n' "$CFG" | sed -nE 's/^features:[[:space:]]*//p')"
echo "  current: features: ${CUR_FEATURES:-<none>}"

if printf '%s' "$CUR_FEATURES" | grep -q 'nesting=1' && printf '%s' "$CUR_FEATURES" | grep -q 'keyctl=1'; then
  step "Already set (nesting=1,keyctl=1) — no change, no reboot."
  exit 0
fi

step "Setting features=$FEATURES on LXC $VMID"
"${SSH[@]}" "pct set $VMID --features $FEATURES" || die "pct set failed."

# If faasd CNI/function networking fails to come up, a tun device is usually the
# missing piece on an unprivileged LXC. Uncomment, re-run, and reboot:
# "${SSH[@]}" "pct set $VMID -dev0 /dev/net/tun,mode=0666" || die "tun passthrough failed."

step "Rebooting LXC $VMID so the new features take effect (241 is empty — safe)"
# `pct reboot` waits for a clean shutdown; fall back to stop/start if it can't.
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

step "Confirming features applied"
NEW="$("${SSH[@]}" "pct config $VMID" | sed -nE 's/^features:[[:space:]]*//p')"
echo "  now: features: ${NEW:-<none>}"
printf '%s' "$NEW" | grep -q 'nesting=1' && printf '%s' "$NEW" | grep -q 'keyctl=1' \
  || die "features not present after set — inspect manually."

step "Done — LXC $VMID has nesting=1,keyctl=1; containerd/faasd can now run there."
