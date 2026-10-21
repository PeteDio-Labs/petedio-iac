#!/usr/bin/env bash
# revoke-claude-ops-node-key.sh — remove claude-ops's root grant on the Proxmox cluster
# (PET-725). Run once, on the Mac, after the claude-code role without the pve02/pve03 targets
# is deployed to 247.
#
# WHY. scripts/seed-claude-ops-ssh.sh (PET-531, deleted in PET-725) authorized claude-ops's
# key for root on pve02 and pve03. Root on a node reaches 247 through `pct exec 247`, which
# would let a session on 247 read the break-glass Vault token from the operator's shell
# (PET-714). Root on hosts is break-glass (PET-725), so the grant goes.
#
# WHAT IT REMOVES. Every line in /etc/pve/priv/authorized_keys that carries claude-ops's key
# MATERIAL (read from 247) or the comment claude-ops@claude-247. It edits the pmxcfs file on
# pve02, never the /root/.ssh/authorized_keys symlink, then proves pve03 sees the same file.
# The key itself stays on 247: it still queues Codex reviews on codex-248 behind a forced
# command (PET-591).
#
# IDEMPOTENT: a re-run with nothing to remove changes nothing and still runs the checks.
#
#   Vault token: none. This script is pure SSH.
#
# Usage:
#   ./scripts/revoke-claude-ops-node-key.sh
set -euo pipefail

PVE02=root@192.168.50.11
PVE03=root@192.168.50.10
PVE_SSH_KEY="${PVE_SSH_KEY:-$HOME/.ssh/id_ed25519_proxmox_pedro}"
on_node() { local host="$1"; shift; ssh -o ConnectTimeout=8 -o IdentitiesOnly=yes -i "$PVE_SSH_KEY" "$host" "$@"; }
CT=247
PUBKEY_PATH=/home/claude-ops/.ssh/id_ed25519.pub
AUTH_KEYS=/etc/pve/priv/authorized_keys
COMMENT=claude-ops@claude-247

die()  { printf '\033[31mERROR\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

command -v ssh >/dev/null || die "ssh not in PATH"
[ -f "$PVE_SSH_KEY" ] || die "No SSH key at $PVE_SSH_KEY. Set PVE_SSH_KEY to the key root on the nodes accepts."

step "Reading claude-ops's public key from CT $CT, via $PVE03"
PUBKEY_LINE="$(on_node "$PVE03" "pct exec $CT -- cat $PUBKEY_PATH" 2>/dev/null || true)"
KEY_MATERIAL="$(printf '%s' "$PUBKEY_LINE" | awk '$1 == "ssh-ed25519" {print $2}')"
if [ -n "$KEY_MATERIAL" ]; then
  echo "  key material: ${#KEY_MATERIAL} characters."
else
  echo "  could not read it; matching on the comment $COMMENT alone."
fi

matches() {
  # Lines that grant claude-ops: by key material when known, and by comment always.
  if [ -n "$KEY_MATERIAL" ]; then
    grep -F -e "$KEY_MATERIAL" -e "$COMMENT" || true
  else
    grep -F -e "$COMMENT" || true
  fi
}

step "Counting claude-ops lines in $AUTH_KEYS on $PVE02"
BEFORE="$(on_node "$PVE02" "cat $AUTH_KEYS")" || die "Could not read $AUTH_KEYS on $PVE02."
TOTAL_BEFORE="$(printf '%s\n' "$BEFORE" | grep -c . || true)"
FOUND="$(printf '%s\n' "$BEFORE" | matches | grep -c . || true)"
echo "  read $TOTAL_BEFORE lines; $FOUND grant claude-ops."

if [ "$FOUND" -gt 0 ]; then
  step "Removing them"
  AFTER="$(printf '%s\n' "$BEFORE" | { if [ -n "$KEY_MATERIAL" ]; then grep -v -F -e "$KEY_MATERIAL" -e "$COMMENT"; else grep -v -F -e "$COMMENT"; fi; } || true)"
  TOTAL_AFTER="$(printf '%s\n' "$AFTER" | grep -c . || true)"
  [ "$TOTAL_AFTER" -eq $((TOTAL_BEFORE - FOUND)) ] \
    || die "Expected $((TOTAL_BEFORE - FOUND)) lines after the removal, got $TOTAL_AFTER. Nothing was written."
  [ "$TOTAL_AFTER" -gt 0 ] || die "The removal would empty $AUTH_KEYS. Nothing was written."
  # Write through a temporary file in /etc/pve/priv, then rename, so a dropped connection never
  # leaves a half-written authorized_keys behind.
  printf '%s\n' "$AFTER" | on_node "$PVE02" "cat > $AUTH_KEYS.pet725 && mv $AUTH_KEYS.pet725 $AUTH_KEYS"
  echo "  wrote $TOTAL_AFTER lines."
fi

step "Proving neither node still grants claude-ops"
for node in "$PVE02" "$PVE03"; do
  # Read first, and fail on a failed read: a pipeline ending in `|| true` would turn an
  # unreachable node into "0 claude-ops lines".
  CONTENT="$(on_node "$node" "cat $AUTH_KEYS")" || die "Could not read $AUTH_KEYS on $node."
  [ -n "$CONTENT" ] || die "$AUTH_KEYS on $node read back empty."
  LEFT="$(printf '%s\n' "$CONTENT" | matches | grep -c . || true)"
  [ "$LEFT" -eq 0 ] || die "$node still has $LEFT claude-ops lines in $AUTH_KEYS. pmxcfs may lag; re-run in a few seconds."
  echo "  $node: 0 claude-ops lines."
done

step "Next"
cat <<TXT
  From 247, as claude-ops, both of these must now fail:
    ssh -o BatchMode=yes -i ~/.ssh/id_ed25519 root@192.168.50.11 true
    ssh -o BatchMode=yes -i ~/.ssh/id_ed25519 root@192.168.50.10 true
  Post the two error lines on PET-725.
TXT
