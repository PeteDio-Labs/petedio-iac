#!/usr/bin/env bash
# seed-claude-ops-ssh.sh — authorize claude-ops's SSH public key on the Proxmox cluster, so
# claude-ops on claude-247 can reach pve02 and pve03 as root (PET-531).
#
# THE KEY IS GENERATED ON 247, AS claude-ops, BY roles/claude-code/tasks/claude-ops.yml. This
# script never sees the private half: it reads the PUBLIC key back from the container, over
# pve02, and never touches the container's filesystem for anything else.
#
# ⚠ /etc/pve/priv/authorized_keys, NEVER /root/.ssh/authorized_keys. On a Proxmox cluster
# node, /root/.ssh/authorized_keys is a SYMLINK into pmxcfs, replaced whenever pve-cluster
# starts. A write there is silently lost at the next restart. /etc/pve/priv/authorized_keys
# is the real file pmxcfs manages, and it propagates to every node in the cluster —
# including pve03, which this script reads back from to prove the propagation actually
# happened rather than assuming it.
#
# ⚠ from="192.168.50.247" RESTRICTS THE KEY TO THIS ONE HOST. Even though the private half
# never leaves claude-247, a restricted line means a copy of authorized_keys leaked from
# anywhere else in the cluster still cannot be used to reach either node AS this key, from
# anywhere but 247.
#
# IDEMPOTENT: re-running this after the key already exists on pve02 changes nothing. It
# compares the key MATERIAL (the base64 blob), not the whole line, so a re-run after this
# script changes the `from=` restriction or the comment still recognizes the same key.
#
#   Vault token: none. This script does not touch Vault — it is pure SSH.
#
# Usage:
#   ./scripts/seed-claude-ops-ssh.sh
set -euo pipefail

PVE02=root@192.168.50.11
PVE03=root@192.168.50.10
# Root on both nodes, by address, with the key named (PET-561). The Mac's `pve03` alias logs in
# as pedro, who cannot read /etc/pve/priv, and the agent holds no key for a bare root@ login.
PVE_SSH_KEY="${PVE_SSH_KEY:-$HOME/.ssh/id_ed25519_proxmox_pedro}"
node() { local host="$1"; shift; ssh -o ConnectTimeout=8 -o IdentitiesOnly=yes -i "$PVE_SSH_KEY" "$host" "$@"; }
CT=247
CT_IP=192.168.50.247
PUBKEY_PATH=/home/claude-ops/.ssh/id_ed25519.pub
AUTH_KEYS=/etc/pve/priv/authorized_keys

die()  { printf '\033[31mERROR\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

command -v ssh >/dev/null || die "ssh not in PATH"
[ -f "$PVE_SSH_KEY" ] || die "No SSH key at $PVE_SSH_KEY. Set PVE_SSH_KEY to the key root on the nodes accepts."

# Via pve03, the node that hosts CT 247: `pct exec` on pve02 answers "Configuration file
# 'nodes/pve02/lxc/247.conf' does not exist" (PET-561).
step "Reading claude-ops's public key from CT $CT, via $PVE03"
PUBKEY_LINE="$(on_node "$PVE03" "pct exec $CT -- cat $PUBKEY_PATH" 2>&1)" \
  || die "Could not read $PUBKEY_PATH on CT $CT via $PVE03:
  $PUBKEY_LINE

  claude_ops_enable must be true and deployed first, which generates the key — see
  roles/claude-code/README.md, claude-ops."

# CONDITION: exactly one line, and it is an ssh-ed25519 key. Anything else means the file on
# 247 is not what tasks/claude-ops.yml generated — do not authorize it blind.
LINE_COUNT="$(printf '%s\n' "$PUBKEY_LINE" | grep -c .)"
[ "$LINE_COUNT" -eq 1 ] || die "$PUBKEY_PATH on CT $CT holds $LINE_COUNT lines, expected exactly 1."
case "$PUBKEY_LINE" in
  ssh-ed25519\ *) ;;
  *) die "$PUBKEY_PATH on CT $CT does not start with 'ssh-ed25519 '. Got: $(printf '%s' "$PUBKEY_LINE" | head -c 40)..." ;;
esac
KEY_MATERIAL="$(printf '%s' "$PUBKEY_LINE" | awk '{print $2}')"
[ -n "$KEY_MATERIAL" ] || die "Could not parse the key material out of the public key line."
echo "  one ssh-ed25519 line, ${#KEY_MATERIAL} characters of key material."

WANT_LINE="from=\"$CT_IP\" ssh-ed25519 $KEY_MATERIAL claude-ops@claude-247"

step "Checking $AUTH_KEYS on $PVE02"
EXISTING="$(on_node "$PVE02" "cat $AUTH_KEYS 2>/dev/null" || true)"
if printf '%s\n' "$EXISTING" | grep -qF "$KEY_MATERIAL"; then
  echo "  claude-ops's key is already present on $PVE02 — nothing to add."
else
  step "Appending claude-ops's key to $AUTH_KEYS on $PVE02"
  # printf on stdin, `tee -a` on the remote: no shell interpolation of the key material
  # happens on either side, and the file is pmxcfs-managed so a normal append is safe — it
  # is not the symlink /root/.ssh/authorized_keys warns about above.
  printf '%s\n' "$WANT_LINE" | on_node "$PVE02" "tee -a $AUTH_KEYS >/dev/null"
  echo "  appended."
fi

step "Proving the cluster propagated it, by reading $AUTH_KEYS back on $PVE03"
# pmxcfs replicates /etc/pve across the cluster; a read that fails here means either pve03 is
# unreachable or the propagation has not caught up yet — re-run in a few seconds.
PROPAGATED="$(on_node "$PVE03" "cat $AUTH_KEYS 2>/dev/null" || true)"
printf '%s\n' "$PROPAGATED" | grep -qF "$KEY_MATERIAL" \
  || die "claude-ops's key is not yet on $PVE03's copy of $AUTH_KEYS. pmxcfs may not have
  caught up — wait a few seconds and re-run. If this persists, check cluster quorum
  (vault/Incidents/2026-09-03-rack-loss.md)."
echo "  present on both $PVE02 and $PVE03."

step "Next"
cat <<TXT
  claude-ops can now reach pve02 and pve03 as root, restricted to connections FROM $CT_IP.
  Prove it, as claude-ops on 247:

    ssh pve02 hostname
    ssh pve03 hostname

  (roles/claude-code/templates/claude-ops-ssh-config.j2 supplies the pve02/pve03 aliases and
  the identity file.)

  Rotation: remove the line naming claude-ops's key material from $AUTH_KEYS on $PVE02,
  delete /home/claude-ops/.ssh/id_ed25519* on 247, re-run tasks/claude-ops.yml (which
  regenerates the key since the file is gone), and re-run this script.
TXT
