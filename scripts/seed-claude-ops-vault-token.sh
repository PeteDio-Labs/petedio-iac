#!/usr/bin/env bash
# seed-claude-ops-vault-token.sh — mint a Vault token bound to the "claude-ops" token role
# and deliver it to claude-ops's home on claude-247, over SSH (PET-531).
#
# THE ROLE NEVER TOUCHES THIS FILE. roles/claude-code/tasks/claude-ops.yml creates
# ~/.config/claude-ops-vault/ (0700 claude-ops) and lands the Vault CA there, and stops: the
# token itself is delivered here, out of band, so it never appears in an Ansible extra-vars
# file, this run's stdout, or Vault's own audit log of a play that reads a hundred other
# things. environments/homelab/vault-config/auth.tf defines the role this mints against:
# allowed_policies=[claude-ops] only, orphan=true, renewable=true, token_period=604800 (7
# days), token_explicit_max_ttl=7776000 (90 days). claude-ops-vault-renew.timer on 247 renews
# it daily; a token nobody renews for 90 days needs a fresh run of this script.
#
# ⚠ NEVER ROOT, NEVER THE UNSEAL KEY. This mints a token SCOPED TO THE claude-ops ROLE, using
# an admin Vault token that stays on the Mac. The token that lands on 247 can hold only the
# "claude-ops" policy — the role itself refuses any other, so a Vault-side change is the only
# way this could ever widen.
#
# DELIVERY: `ssh root@192.168.50.10 "pct exec 247 -- ..."` — pve03, which reaches every LXC
# on the cluster the same way scripts/deploy-pete-bot.sh already does for CT 237. The token
# travels on stdin into a `tee` inside the container, never as a `pct exec` argument, where
# `ps` on either hop would show it.
#
#   Vault token: $VAULT_TOKEN, else macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM. No
#   interactive prompt (PET-531's explicit instruction) — set one of those first, or this
#   refuses to run.
#
# Usage:
#   ./scripts/seed-claude-ops-vault-token.sh
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"

PVE03="root@192.168.50.10"
# The Mac's ~/.ssh/config has no Host block for this address, and its agent holds no key, so a
# bare `ssh root@192.168.50.10` offers id_rsa and pve03 refuses it (PET-561). Name the key.
PVE_SSH_KEY="${PVE_SSH_KEY:-$HOME/.ssh/id_ed25519_proxmox_pedro}"
pve03() { ssh -o ConnectTimeout=8 -o IdentitiesOnly=yes -i "$PVE_SSH_KEY" "$PVE03" "$@"; }
CT=247
TOKEN_PATH="/home/claude-ops/.config/claude-ops-vault/token"
ROLE=claude-ops

die()  { printf '\033[31mERROR\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

for t in vault jq ssh; do command -v "$t" >/dev/null || die "$t not in PATH"; done
[ -f "$PVE_SSH_KEY" ] || die "No SSH key at $PVE_SSH_KEY. Set PVE_SSH_KEY to the key root@pve03 accepts."

# Before the mint, not after it: a run that dies here leaves no token behind (PET-561).
step "Checking the destination directory exists on claude-247"
pve03 "pct exec $CT -- test -d /home/claude-ops/.config/claude-ops-vault" \
  || die "/home/claude-ops/.config/claude-ops-vault does not exist on CT $CT, or pve03 refused SSH.
  claude_ops_enable must be true and deployed first — see roles/claude-code/README.md, claude-ops."

step "Authenticating to Vault"
[ -f "$VAULT_CACERT" ] || die "VAULT_CACERT not found at '$VAULT_CACERT'.
  Run this from inside the repo, or export VAULT_CACERT explicitly."
if [ -z "${VAULT_TOKEN:-}" ]; then
  VAULT_TOKEN="$(security find-generic-password -s "$VAULT_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null || true)"
fi
[ -n "${VAULT_TOKEN:-}" ] || die "no Vault token: set VAULT_TOKEN or add the Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM. This script does not prompt."
export VAULT_TOKEN
vault token lookup >/dev/null 2>&1 || die "Vault rejected the token, or $VAULT_ADDR is unreachable."

step "Checking the claude-ops token role exists"
vault read -field=allowed_policies "auth/token/roles/$ROLE" >/dev/null 2>&1 \
  || die "auth/token/roles/$ROLE does not exist. Apply environments/homelab/vault-config first: ./scripts/apply-vault-config.sh"

step "Minting a token bound to the $ROLE role"
# -format=json for the accessor, which is safe to hold in a shell variable and pass on argv —
# it identifies the token for lookup/revocation but grants nothing by itself. The token
# itself (.auth.client_token) is handled the same as every other secret in this script: held
# only in a variable, never echoed, never passed as an argument.
#
# -period and -explicit-max-ttl repeat the role's token_period and token_explicit_max_ttl.
# Vault 2.0 mints a role token without them: the 2026-10-02 run got a 7-day TTL with no
# period and no cap, so the shape check below refused it (PET-561). The role still bounds
# the policies, and the shape check still proves what the mint produced.
MINT_JSON="$(vault token create -role="$ROLE" -period=168h -explicit-max-ttl=2160h -format=json)"
TOKEN="$(printf '%s' "$MINT_JSON" | jq -r '.auth.client_token // empty')"
ACCESSOR="$(printf '%s' "$MINT_JSON" | jq -r '.auth.accessor // empty')"
unset MINT_JSON
[ -n "$TOKEN" ] && [ -n "$ACCESSOR" ] || die "vault token create did not return a token. Check the role and try again."
echo "  accessor $ACCESSOR"

# Any exit before the delivery is verified revokes this token, so a failure past this point
# never leaves an orphan nobody can find (PET-561: one run left one).
DELIVERED=0
revoke_unless_delivered() {
  [ "$DELIVERED" -eq 1 ] && return 0
  if vault token revoke -accessor "$ACCESSOR" >/dev/null 2>&1; then
    echo "  Revoked the undelivered token (accessor $ACCESSOR)." >&2
  else
    echo "  Could not revoke accessor $ACCESSOR. Run: vault token revoke -accessor $ACCESSOR" >&2
  fi
}
trap revoke_unless_delivered EXIT

step "Verifying the minted token's shape (by accessor, never the token itself)"
# Flags before the positional argument: -accessor is a boolean, so a flag after "$ACCESSOR"
# reads as a second argument and the CLI refuses with "Too many arguments" (PET-561).
LOOKUP_JSON="$(vault token lookup -format=json -accessor "$ACCESSOR")"
POLICIES="$(printf '%s' "$LOOKUP_JSON" | jq -r '.data.policies | sort | join(",")')"
ORPHAN="$(printf '%s' "$LOOKUP_JSON" | jq -r '.data.orphan')"
RENEWABLE="$(printf '%s' "$LOOKUP_JSON" | jq -r '.data.renewable')"
PERIOD="$(printf '%s' "$LOOKUP_JSON" | jq -r '.data.period')"
EXPLICIT_MAX_TTL="$(printf '%s' "$LOOKUP_JSON" | jq -r '.data.explicit_max_ttl')"

[ "$POLICIES" = "claude-ops" ] || [ "$POLICIES" = "claude-ops,default" ] \
  || die "Minted token carries policies '$POLICIES', not just claude-ops (plus Vault's implicit default). Revoke it (vault token revoke -accessor $ACCESSOR) and check the role."
[ "$ORPHAN" = "true" ] || die "Minted token has orphan=$ORPHAN, expected true. Revoke it and check the role."
[ "$RENEWABLE" = "true" ] || die "Minted token has renewable=$RENEWABLE, expected true. Revoke it and check the role."
[ "$PERIOD" = "604800" ] || die "Minted token has period=$PERIOD, expected 604800 (7 days). Revoke it and check the role."
[ "$EXPLICIT_MAX_TTL" = "7776000" ] || die "Minted token has explicit_max_ttl=$EXPLICIT_MAX_TTL, expected 7776000 (90 days). Revoke it and check the role."
unset LOOKUP_JSON
echo "  policies=$POLICIES orphan=$ORPHAN renewable=$RENEWABLE period=${PERIOD}s explicit_max_ttl=${EXPLICIT_MAX_TTL}s"

step "Delivering the token over SSH (stdin only, never an argument)"
# printf '%s' — no trailing newline. Vault's own SDKs trim one, but the renewal script here
# does not add one back either, so the file on disk is exactly the token, byte for byte.
#
# `install -m 0400 -o claude-ops -g claude-ops /dev/stdin` — not `tee` followed by a separate
# chown and chmod. `install` creates the destination file with its final owner and mode in
# one step, so the file is never briefly world- or group-readable (or root-owned) between a
# `tee` and the chmod that would have followed it.
printf '%s' "$TOKEN" \
  | pve03 "pct exec $CT -- install -m 0400 -o claude-ops -g claude-ops /dev/stdin $TOKEN_PATH"
unset TOKEN

step "Verifying delivery (length only, never the contents)"
# `stat` inside the container, not `wc -c < $TOKEN_PATH`: in a remote command string, pve03's
# shell opens a `<` redirect on pve03, where the path does not exist (PET-561).
read -r LEN MODE <<<"$(pve03 "pct exec $CT -- stat -c '%s %a %U:%G' $TOKEN_PATH")"
[ "${LEN:-0}" -gt 0 ] || die "The delivered file is empty. Something ate the token in transit — re-run."
DELIVERED=1
echo "  $TOKEN_PATH is $LEN bytes, mode $MODE."

step "Next"
cat <<TXT
  claude-ops-vault-renew.timer on 247 renews this token daily. It expires 7 days after its
  last renewal (token_period) and cannot be renewed past 90 days from this mint
  (token_explicit_max_ttl) — re-run this script before then.

  Prove it works, as claude-ops on 247:
    VAULT_ADDR=https://192.168.50.223:8200 VAULT_CACERT=~/.config/claude-ops-vault/ca.pem \\
      VAULT_TOKEN="\$(cat ~/.config/claude-ops-vault/token)" vault token lookup -field=policies
TXT
