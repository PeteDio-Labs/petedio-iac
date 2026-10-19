#!/usr/bin/env bash
# place-claude-ops-ansible-key.sh — copy the Mac's id_ed25519_ansible to claude-ops on 247, so
# claude-ops can SSH to the media hosts as root (PET-662).
#
# ⚠ THIS COPIES A PRIVATE KEY OFF THE MAC. Pedro chose the copy over a key generated on 247 on
# 2026-10-19 (PET-662, the 03:43 and 03:50 comments). The key reaches every host that trusts
# id_ed25519_ansible, not only the media LXCs. To take that reach back, rotate the key on every
# host that trusts it; deleting the copy on 247 alone does not revoke anything.
#
# Run it on the Mac, on Pedro's word (PET-511). It needs root on pve03, the node that hosts
# CT 247: `pct exec` on pve02 answers "Configuration file 'nodes/pve02/lxc/247.conf' does not
# exist" (PET-561).
#
# THE PRIVATE KEY TRAVELS ON STDIN ONLY. It is never an argument, never printed, and never
# written outside /home/claude-ops/.ssh/ on 247. Every check below compares public halves and
# fingerprints, which `ssh-keygen -y` and `ssh-keygen -lf` derive without printing the key.
#
# DELIVERY: `cat` inside the container, not `install ... /dev/stdin`. CT 247 is unprivileged,
# so its root cannot reopen the host-owned pipe by path: "cannot open '/dev/stdin' for
# reading: Permission denied" (PET-561, scripts/seed-claude-ops-vault-token.sh).
#
# IDEMPOTENT: when 247 already holds the same key, this script changes nothing. When 247 holds
# a DIFFERENT key at the same path, it stops rather than overwrite it.
#
#   Vault token: none. This script does not touch Vault — it is pure SSH.
#
# Usage:
#   ./scripts/place-claude-ops-ansible-key.sh
set -euo pipefail

PVE03=root@192.168.50.10
PVE_SSH_KEY="${PVE_SSH_KEY:-$HOME/.ssh/id_ed25519_proxmox_pedro}"
SRC_KEY="${SRC_KEY:-$HOME/.ssh/id_ed25519_ansible}"
CT=247
DEST_DIR=/home/claude-ops/.ssh
DEST_KEY="$DEST_DIR/id_ed25519_ansible"

die()  { printf '\033[31mERROR\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
pve03() { ssh -o ConnectTimeout=8 -o IdentitiesOnly=yes -i "$PVE_SSH_KEY" "$PVE03" "$@"; }
# The key material only: the second field of a public key line, without its comment.
material() { awk 'NR==1 {print $2}'; }

command -v ssh >/dev/null || die "ssh not in PATH"
command -v ssh-keygen >/dev/null || die "ssh-keygen not in PATH"
[ -f "$PVE_SSH_KEY" ] || die "No SSH key at $PVE_SSH_KEY. Set PVE_SSH_KEY to the key root on pve03 accepts."
[ -f "$SRC_KEY" ] || die "No private key at $SRC_KEY. Set SRC_KEY to id_ed25519_ansible's path."
[ -f "$SRC_KEY.pub" ] || die "No public key at $SRC_KEY.pub."

step "Checking the Mac's key pair"
# The .pub must be the private key's own public half, or 247 would receive a mismatched pair.
SRC_MATERIAL="$(ssh-keygen -y -f "$SRC_KEY" </dev/null | material)" \
  || die "ssh-keygen could not read $SRC_KEY. A passphrase-protected key cannot be used unattended on 247."
[ -n "$SRC_MATERIAL" ] || die "Could not derive a public key from $SRC_KEY."
[ "$(material < "$SRC_KEY.pub")" = "$SRC_MATERIAL" ] || die "$SRC_KEY.pub is not the public half of $SRC_KEY."
case "$(head -c 12 "$SRC_KEY.pub")" in
  ssh-ed25519\ ) ;;
  *) die "$SRC_KEY.pub is not an ssh-ed25519 key." ;;
esac
SRC_FP="$(ssh-keygen -lf "$SRC_KEY.pub" | awk '{print $2}')"
echo "  pair matches, fingerprint $SRC_FP."

step "Checking claude-ops on CT $CT, via $PVE03"
pve03 "pct exec $CT -- test -d $DEST_DIR" \
  || die "$DEST_DIR does not exist on CT $CT. Deploy the claude-code role with claude_ops_enable true first."

# A key already on 247: derive its public half there. Equal → done; different → stop.
if pve03 "pct exec $CT -- test -e $DEST_KEY"; then
  HAVE_MATERIAL="$(pve03 "pct exec $CT -- ssh-keygen -y -f $DEST_KEY" </dev/null 2>/dev/null | material || true)"
  if [ "$HAVE_MATERIAL" = "$SRC_MATERIAL" ]; then
    echo "  $DEST_KEY already holds this key — nothing to copy."
    ALREADY=1
  else
    die "$DEST_KEY on CT $CT holds a different or unreadable key. Read it before you remove it; this script never overwrites a key."
  fi
fi

if [ -z "${ALREADY:-}" ]; then
  step "Copying the key pair to CT $CT (stdin only, never an argument)"
  # umask 0177 creates the private key as mode 0600 from the first byte. It is root-owned only
  # until the chown, inside claude-ops's 0700 .ssh, and the mv swaps it into place whole.
  pve03 "pct exec $CT -- sh -c 'umask 0177 && cat > $DEST_KEY.new && chown claude-ops:claude-ops $DEST_KEY.new && mv -f $DEST_KEY.new $DEST_KEY'" \
    < "$SRC_KEY"
  pve03 "pct exec $CT -- sh -c 'umask 0133 && cat > $DEST_KEY.pub.new && chown claude-ops:claude-ops $DEST_KEY.pub.new && mv -f $DEST_KEY.pub.new $DEST_KEY.pub'" \
    < "$SRC_KEY.pub"
  echo "  copied."
fi

step "Verifying on CT $CT (owner, mode and fingerprint only, never the contents)"
read -r KEY_MODE KEY_OWNER <<<"$(pve03 "pct exec $CT -- stat -c '%a %U:%G' $DEST_KEY")"
read -r PUB_MODE PUB_OWNER <<<"$(pve03 "pct exec $CT -- stat -c '%a %U:%G' $DEST_KEY.pub")"
[ "$KEY_MODE" = "600" ] && [ "$KEY_OWNER" = "claude-ops:claude-ops" ] \
  || die "$DEST_KEY is mode $KEY_MODE, owner $KEY_OWNER. Expected 600, claude-ops:claude-ops."
[ "$PUB_MODE" = "644" ] && [ "$PUB_OWNER" = "claude-ops:claude-ops" ] \
  || die "$DEST_KEY.pub is mode $PUB_MODE, owner $PUB_OWNER. Expected 644, claude-ops:claude-ops."
# Derive the public half from the PLACED private key, so an empty or truncated copy fails here
# rather than at claude-ops's first login.
DEST_MATERIAL="$(pve03 "pct exec $CT -- ssh-keygen -y -f $DEST_KEY" </dev/null | material || true)"
[ "$DEST_MATERIAL" = "$SRC_MATERIAL" ] \
  || die "The private key on CT $CT does not derive the Mac's public key. Remove $DEST_KEY and re-run."
DEST_FP="$(pve03 "pct exec $CT -- ssh-keygen -lf $DEST_KEY.pub" </dev/null | awk '{print $2}')"
[ "$DEST_FP" = "$SRC_FP" ] || die "Fingerprint on CT $CT is $DEST_FP, expected $SRC_FP."
echo "  $DEST_KEY: mode $KEY_MODE, $KEY_OWNER. $DEST_KEY.pub: mode $PUB_MODE, $PUB_OWNER."
echo "  fingerprint $DEST_FP on both sides."

step "Next"
cat <<TXT
  Record the fingerprint on PET-662: $SRC_FP

  Prove it, as claude-ops on 247, for each media host address:

    ssh -n -o BatchMode=yes -o IdentitiesOnly=yes -i ~/.ssh/id_ed25519_ansible root@<addr> true

  To remove the copy, delete $DEST_KEY and $DEST_KEY.pub on CT $CT. That stops 247 using the
  key but revokes nothing: rotate id_ed25519_ansible on every host that trusts it.
TXT
