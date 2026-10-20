#!/usr/bin/env bash
# rotate-approle-secret-id.sh — replace the secret_id the Mac holds for the `ansible` or
# `terraform-local` AppRole, then destroy the old one (PET-687).
#
# WHY: before PET-687 these secret_ids never expired and worked from any address
# (vault-config/auth.tf). The role now sets secret_id_ttl, which applies only to secret_ids
# minted after the apply. This script mints a new one under that TTL, proves it logs in,
# and destroys the old one, so no secret_id from before the apply stays valid.
#
# Run it on the Mac, on Pedro's word (PET-511), after scripts/apply-vault-config.sh has
# applied PET-687. It touches only iac/.secrets/<role>.{role_id,secret_id,secret_id_accessor}.
#
#   Vault token: $VAULT_TOKEN, else macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM. No prompt.
#
# THE SECRET_ID NEVER REACHES AN ARGUMENT LIST. It goes from `vault write` output into a file
# created with mode 0600, and the proof sends it to Vault as JSON on stdin. Nothing prints it.
#
# ORDER, SO A FAILED RUN LEAVES A WORKING LOGIN: mint, write the new file beside the old one,
# prove the new secret_id logs in from this machine, then move it into place and destroy the
# old secret_id. A run that dies before the proof destroys the secret_id it minted and leaves
# the old files as they were.
#
# THE OLD SECRET_ID. The accessor of the secret_id in use is recorded in
# <role>.secret_id_accessor from the first rotation on. Before that, no accessor is recorded,
# so pass --destroy-others to destroy every other secret_id on the role. That also revokes a
# copy on another host, which is the point when you cannot say who holds one.
#
# Usage:
#   ./scripts/rotate-approle-secret-id.sh ansible [--destroy-others]
#   ./scripts/rotate-approle-secret-id.sh terraform-local [--destroy-others]
set -euo pipefail
umask 077

ROLE=""
DESTROY_OTHERS=0
for arg in "$@"; do
  case "$arg" in
    ansible|terraform-local) ROLE="$arg" ;;
    --destroy-others) DESTROY_OTHERS=1 ;;
    -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
    *) printf 'unknown argument: %s (try --help)\n' "$arg" >&2; exit 2 ;;
  esac
done
[ -n "$ROLE" ] || { printf 'usage: %s ansible|terraform-local [--destroy-others]\n' "${0##*/}" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"
SECRETS="${SECRETS_DIR:-$REPO_ROOT/.secrets}"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"

die()  { printf '\033[31mERROR\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m==>\033[0m %s\n' "$*"; }

for t in vault jq; do command -v "$t" >/dev/null || die "$t not in PATH"; done
[ -f "$VAULT_CACERT" ] || die "VAULT_CACERT not found at '$VAULT_CACERT'."
[ -d "$SECRETS" ] || die "$SECRETS does not exist. Create it as the vault-seed runbook says."
(cd "$REPO_ROOT" && git check-ignore -q "${SECRETS#"$REPO_ROOT"/}/$ROLE.secret_id") \
  || die "$SECRETS is not gitignored. Pull main before anything lands in it."

step "Authenticating to Vault"
if [ -z "${VAULT_TOKEN:-}" ]; then
  VAULT_TOKEN="$(security find-generic-password -s "$VAULT_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null || true)"
fi
[ -n "${VAULT_TOKEN:-}" ] || die "no Vault token: set VAULT_TOKEN or add the Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM."
export VAULT_TOKEN
vault token lookup >/dev/null 2>&1 || die "Vault rejected the token, or $VAULT_ADDR is unreachable."

step "Checking the $ROLE role"
ROLE_JSON="$(vault read -format=json "auth/approle/role/$ROLE")" \
  || die "auth/approle/role/$ROLE does not exist."
TTL="$(jq -r '.data.secret_id_ttl' <<<"$ROLE_JSON")"
[ "$TTL" -gt 0 ] 2>/dev/null \
  || die "$ROLE has no secret_id_ttl. Apply PET-687 first: ./scripts/apply-vault-config.sh"
echo "  secret_id_ttl=${TTL}s, secret_id_bound_cidrs=$(jq -c '.data.secret_id_bound_cidrs' <<<"$ROLE_JSON")"
unset ROLE_JSON

OLD_ACCESSOR=""
[ -f "$SECRETS/$ROLE.secret_id_accessor" ] && OLD_ACCESSOR="$(cat "$SECRETS/$ROLE.secret_id_accessor")"
if [ -z "$OLD_ACCESSOR" ] && [ "$DESTROY_OTHERS" -eq 0 ]; then
  echo "  No accessor is recorded for the secret_id in use, so this run cannot destroy it."
  echo "  It mints a new secret_id and leaves the old one valid. Pass --destroy-others to destroy it."
fi

role_id="$(vault read -field=role_id "auth/approle/role/$ROLE/role-id")"
[ -n "$role_id" ] || die "Vault returned no role_id for $ROLE."

step "Minting a secret_id"
MINT="$(vault write -format=json -f "auth/approle/role/$ROLE/secret-id" \
  metadata='{"host":"mac","pet":"PET-687"}')"
NEW_ID="$(jq -r '.data.secret_id // empty' <<<"$MINT")"
NEW_ACCESSOR="$(jq -r '.data.secret_id_accessor // empty' <<<"$MINT")"
unset MINT
[ -n "$NEW_ID" ] && [ -n "$NEW_ACCESSOR" ] || die "vault write did not return a secret_id."
echo "  accessor $NEW_ACCESSOR"

PROVEN=0
cleanup() {
  [ "$PROVEN" -eq 1 ] && return 0
  rm -f "$SECRETS/$ROLE.secret_id.new"
  if vault write "auth/approle/role/$ROLE/secret-id-accessor/destroy" secret_id_accessor="$NEW_ACCESSOR" >/dev/null 2>&1; then
    echo "  Destroyed the unproven secret_id (accessor $NEW_ACCESSOR). The old files are unchanged." >&2
  else
    echo "  Could not destroy accessor $NEW_ACCESSOR. Run: vault write auth/approle/role/$ROLE/secret-id-accessor/destroy secret_id_accessor=$NEW_ACCESSOR" >&2
  fi
}
trap cleanup EXIT

# The new secret_id is written beside the old one, mode 0600 from its first byte.
printf '%s' "$NEW_ID" > "$SECRETS/$ROLE.secret_id.new"

step "Proving the new secret_id logs in from this machine"
# Credentials go to Vault as JSON on stdin from the printf builtin, the way the deploy scripts do.
TOKEN="$(printf '{"role_id":"%s","secret_id":"%s"}' "$role_id" "$(cat "$SECRETS/$ROLE.secret_id.new")" \
  | vault write -field=token auth/approle/login - 2>/dev/null)" \
  || die "The new secret_id did not log in. If secret_id_bound_cidrs is set, this machine's address may be outside it."
[ -n "$TOKEN" ] || die "login returned no token."
POLICIES="$(VAULT_TOKEN="$TOKEN" vault token lookup -format=json | jq -r '.data.policies|sort|join(",")')"
VAULT_TOKEN="$TOKEN" vault token revoke -self >/dev/null 2>&1 || die "Could not revoke the proof token."
unset TOKEN NEW_ID
echo "  login=ok policies=$POLICIES (token revoked)"
PROVEN=1

step "Moving the new files into place"
printf '%s' "$role_id" > "$SECRETS/$ROLE.role_id.new"
printf '%s' "$NEW_ACCESSOR" > "$SECRETS/$ROLE.secret_id_accessor.new"
mv -f "$SECRETS/$ROLE.role_id.new" "$SECRETS/$ROLE.role_id"
mv -f "$SECRETS/$ROLE.secret_id.new" "$SECRETS/$ROLE.secret_id"
mv -f "$SECRETS/$ROLE.secret_id_accessor.new" "$SECRETS/$ROLE.secret_id_accessor"
chmod 600 "$SECRETS/$ROLE.role_id" "$SECRETS/$ROLE.secret_id" "$SECRETS/$ROLE.secret_id_accessor"
for f in role_id secret_id; do
  read -r LEN MODE <<<"$(stat -f '%z %Lp' "$SECRETS/$ROLE.$f" 2>/dev/null || stat -c '%s %a' "$SECRETS/$ROLE.$f")"
  [ "${LEN:-0}" -gt 0 ] && [ "$MODE" = "600" ] || die "$SECRETS/$ROLE.$f is $LEN bytes, mode $MODE. Expected non-empty, 600."
  echo "  $ROLE.$f: $LEN bytes, mode $MODE."
done

destroy() {
  local err
  if err="$(vault write "auth/approle/role/$ROLE/secret-id-accessor/destroy" secret_id_accessor="$1" 2>&1 >/dev/null)"; then
    echo "  destroyed accessor $1."
  elif grep -q 'failed to find accessor entry' <<<"$err"; then
    echo "  accessor $1 was already gone."
  else
    die "Vault refused to destroy accessor $1, so that secret_id may still log in: $err"
  fi
}

if [ -n "$OLD_ACCESSOR" ] && [ "$OLD_ACCESSOR" != "$NEW_ACCESSOR" ]; then
  step "Destroying the replaced secret_id"
  destroy "$OLD_ACCESSOR"
fi
if [ "$DESTROY_OTHERS" -eq 1 ]; then
  step "Destroying every other secret_id on $ROLE"
  COUNT=0
  while read -r acc; do
    [ -n "$acc" ] && [ "$acc" != "$NEW_ACCESSOR" ] || continue
    destroy "$acc"; COUNT=$((COUNT + 1))
  done < <(vault list -format=json "auth/approle/role/$ROLE/secret-id" | jq -r '.[]')
  echo "  destroyed $COUNT other secret_id(s). The new one is the only one left."
fi

step "Next"
cat <<TXT
  Record the accessor on PET-687: $NEW_ACCESSOR
  Run a deploy from this machine to confirm it logs in, for example ./scripts/vault-verify.sh.
  Rotate again before the secret_id expires, ${TTL}s after the mint.
TXT
