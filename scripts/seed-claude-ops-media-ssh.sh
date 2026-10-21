#!/usr/bin/env bash
# seed-claude-ops-media-ssh.sh — authorize claude-ops's media-only key for root on the seven
# media hosts (PET-725). Run once, on the Mac, after the claude-code role that generates the
# key is deployed to 247.
#
# WHY A NEW KEY. Until PET-725, claude-ops reached the media hosts with a copy of the Mac's
# id_ed25519_ansible (PET-662). That key is also root on 247 and every core LXC, so holding
# it let a session on 247 reach the break-glass token in the operator's shell (PET-714). The
# role deletes that copy and generates ~/.ssh/id_ed25519_media, which opens these hosts only.
#
# THE PRIVATE HALF NEVER LEAVES 247. This script reads the PUBLIC key back over pve03's
# `pct exec`, then appends it to /root/.ssh/authorized_keys on each host with the Mac's own
# ansible key. It compares key material, so a re-run adds nothing twice.
#
# A media LXC is unprivileged, so root there does not reach its node or 247.
#
#   Vault token: none. This script is pure SSH.
#
# Usage:
#   ./scripts/seed-claude-ops-media-ssh.sh
set -euo pipefail

PVE03=root@192.168.50.10
PVE_SSH_KEY="${PVE_SSH_KEY:-$HOME/.ssh/id_ed25519_proxmox_pedro}"
MEDIA_SSH_KEY="${MEDIA_SSH_KEY:-$HOME/.ssh/id_ed25519_ansible}"
CT=247
PUBKEY_PATH=/home/claude-ops/.ssh/id_ed25519_media.pub

# name address — keep in step with claude_ops_ssh_targets in roles/claude-code/defaults/main.yml.
HOSTS=(
  "seerr 192.168.50.33"
  "sonarr 192.168.50.15"
  "radarr 192.168.50.16"
  "prowlarr 192.168.50.20"
  "qbittorrent-vpn 192.168.50.21"
  "plex-gpu 192.168.86.236"
  "media-dash-237 192.168.50.237"
)

die()  { printf '\033[31mERROR\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

command -v ssh >/dev/null || die "ssh not in PATH"
[ -f "$PVE_SSH_KEY" ] || die "No SSH key at $PVE_SSH_KEY. Set PVE_SSH_KEY."
[ -f "$MEDIA_SSH_KEY" ] || die "No SSH key at $MEDIA_SSH_KEY. Set MEDIA_SSH_KEY to the key root on the media hosts accepts."

step "Reading claude-ops's media public key from CT $CT, via $PVE03"
PUBKEY_LINE="$(ssh -o ConnectTimeout=8 -o IdentitiesOnly=yes -i "$PVE_SSH_KEY" "$PVE03" \
  "pct exec $CT -- cat $PUBKEY_PATH" 2>&1)" \
  || die "Could not read $PUBKEY_PATH on CT $CT: $PUBKEY_LINE
  Deploy the claude-code role first; it generates the key."
[ "$(printf '%s\n' "$PUBKEY_LINE" | grep -c .)" -eq 1 ] || die "$PUBKEY_PATH holds more than one line."
case "$PUBKEY_LINE" in
  ssh-ed25519\ *claude-ops-media@claude-247) ;;
  *) die "$PUBKEY_PATH is not the ssh-ed25519 key the role generates (comment claude-ops-media@claude-247)." ;;
esac
KEY_MATERIAL="$(printf '%s' "$PUBKEY_LINE" | awk '{print $2}')"
echo "  one ssh-ed25519 line, ${#KEY_MATERIAL} characters of key material."

FAILED=0
for entry in "${HOSTS[@]}"; do
  name="${entry%% *}"; addr="${entry##* }"
  step "$name ($addr)"
  on_host() { ssh -o ConnectTimeout=8 -o IdentitiesOnly=yes -i "$MEDIA_SSH_KEY" "root@$addr" "$@"; }
  if ! existing="$(on_host 'cat /root/.ssh/authorized_keys 2>/dev/null; true')"; then
    echo "  unreachable; skipped."; FAILED=$((FAILED + 1)); continue
  fi
  if printf '%s\n' "$existing" | grep -qF "$KEY_MATERIAL"; then
    echo "  already authorized."
  else
    printf '%s\n' "$PUBKEY_LINE" | on_host 'umask 077; mkdir -p /root/.ssh && cat >> /root/.ssh/authorized_keys'
    on_host 'cat /root/.ssh/authorized_keys' | grep -qF "$KEY_MATERIAL" \
      || { echo "  appended, but the read-back does not show it."; FAILED=$((FAILED + 1)); continue; }
    echo "  authorized."
  fi
done

step "Result"
echo "  ${#HOSTS[@]} hosts read; $FAILED failed."
[ "$FAILED" -eq 0 ] || die "$FAILED of ${#HOSTS[@]} hosts are not authorized. Fix them and re-run."
cat <<TXT
  From 247, as claude-ops, each alias must now connect: ssh seerr true, and so on.
  Post the result on PET-725.
TXT
