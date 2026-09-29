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
CT=247
TOKEN_PATH="/home/claude-ops/.config/claude-ops-vault/token"
ROLE=claude-ops

die()  { printf '\033[31mERROR\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

for t in vault jq ssh; do command -v "$t" >/dev/null || die "$t not in PATH"; done

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
MINT_JSON="$(vault token create -role="$ROLE" -format=json)"
TOKEN="$(printf '%s' "$MINT_JSON" | jq -r '.auth.client_token // empty')"
ACCESSOR="$(printf '%s' "$MINT_JSON" | jq -r '.auth.accessor // empty')"
unset MINT_JSON
[ -n "$TOKEN" ] && [ -n "$ACCESSOR" ] || die "vault token create did not return a token. Check the role and try again."

step "Verifying the minted token's shape (by accessor, never the token itself)"
LOOKUP_JSON="$(vault token lookup -accessor "$ACCESSOR" -format=json)"
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

step "Checking the destination directory exists on claude-247"
ssh -o ConnectTimeout=8 "$PVE03" "pct exec $CT -- test -d /home/claude-ops/.config/claude-ops-vault" \
  || die "/home/claude-ops/.config/claude-ops-vault does not exist on CT $CT.
  claude_ops_enable must be true and deployed first — see roles/claude-code/README.md, claude-ops."

step "Delivering the token over SSH (stdin only, never an argument)"
# printf '%s' — no trailing newline. Vault's own SDKs trim one, but the renewal script here
# does not add one back either, so the file on disk is exactly the token, byte for byte.
printf '%s' "$TOKEN" | ssh -o ConnectTimeout=8 "$PVE03" "pct exec $CT -- tee $TOKEN_PATH >/dev/null"
unset TOKEN
ssh -o ConnectTimeout=8 "$PVE03" "pct exec $CT -- chown claude-ops:claude-ops $TOKEN_PATH"
ssh -o ConnectTimeout=8 "$PVE03" "pct exec $CT -- chmod 0400 $TOKEN_PATH"

step "Verifying delivery (length only, never the contents)"
LEN="$(ssh -o ConnectTimeout=8 "$PVE03" "pct exec $CT -- wc -c < $TOKEN_PATH" | tr -d ' ')"
MODE="$(ssh -o ConnectTimeout=8 "$PVE03" "pct exec $CT -- stat -c '%a %U:%G' $TOKEN_PATH")"
[ "$LEN" -gt 0 ] || die "The delivered file is empty. Something ate the token in transit — re-run."
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
