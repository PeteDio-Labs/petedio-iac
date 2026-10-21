#!/usr/bin/env bash
# seed-breakglass-247.sh — enrol Pedro for the break-glass Vault login on claude-247 (PET-714).
#
# Run once, on the Mac, after environments/homelab/vault-config/breakglass.tf is applied. It:
#   1. creates the userpass user with a password you type (never echoed, never on argv),
#      bound to the breakglass-247 policy, a one-hour token and 247's address only.
#      token_explicit_max_ttl fixes the ceiling INTO each issued token: the token is renewable,
#      and Vault re-reads the user's token_max_ttl at renewal, which this policy could raise.
#      The explicit max cannot be raised for a token already issued;
#   2. creates the identity entity and the alias that ties the user to it;
#   3. enrols that entity on the TOTP method, and shows the QR code for your authenticator app.
#
# NO SECRET LEAVES THIS RUN. The password goes to Vault on stdin. The TOTP QR is written to a
# private temporary directory, opened, and deleted when you press Enter. This script prints
# neither, and nothing lands in the repo, Vault's KV or 247.
#
#   Vault token: $VAULT_TOKEN, else macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM. No prompt
#   for the token (PET-531) — set one of those first, or this refuses to run.
#
# Usage:
#   ./scripts/seed-breakglass-247.sh            first enrolment
#   ./scripts/seed-breakglass-247.sh --reenrol  a lost phone: new password and new TOTP secret
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"

USERNAME=pedro
MOUNT=userpass
POLICY=breakglass-247
ENTITY=pedro-breakglass
BOUND_CIDR=192.168.50.247/32
ISSUER="PeteDio Vault"

REENROL=0
for arg in "$@"; do
  case "$arg" in
    --reenrol) REENROL=1 ;;
    -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
    *) printf 'unknown argument: %s (try --help)\n' "$arg" >&2; exit 2 ;;
  esac
done

die()  { printf '\033[31mERROR\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

for t in vault jq base64; do command -v "$t" >/dev/null || die "$t not in PATH"; done

step "Authenticating to Vault"
[ -f "$VAULT_CACERT" ] || die "VAULT_CACERT not found at '$VAULT_CACERT'."
if [ -z "${VAULT_TOKEN:-}" ]; then
  VAULT_TOKEN="$(security find-generic-password -s "$VAULT_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null || true)"
fi
[ -n "${VAULT_TOKEN:-}" ] || die "no Vault token: set VAULT_TOKEN or add the Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM."
export VAULT_TOKEN
vault token lookup >/dev/null 2>&1 || die "Vault rejected the token, or $VAULT_ADDR is unreachable."

step "Checking breakglass.tf is applied"
ACCESSOR="$(vault auth list -format=json | jq -r --arg m "$MOUNT/" '.[$m].accessor // empty')"
[ -n "$ACCESSOR" ] || die "no $MOUNT/ auth mount. Apply vault-config first: ./scripts/apply-vault-config.sh"
vault policy read "$POLICY" >/dev/null 2>&1 || die "no $POLICY policy. Apply vault-config first."
METHOD_ID="$(vault list -format=json identity/mfa/method/totp 2>/dev/null \
  | jq -r '.[]?' | while read -r id; do
      if [ "$(vault read -field=issuer "identity/mfa/method/totp/$id")" = "$ISSUER" ]; then
        echo "$id"
      fi
    done)"
[ "$(printf '%s\n' "$METHOD_ID" | grep -c .)" = 1 ] \
  || die "expected exactly one TOTP method with issuer '$ISSUER', found: '${METHOD_ID:-none}'. Apply vault-config first."
vault read "identity/mfa/login-enforcement/$POLICY" >/dev/null 2>&1 \
  || die "no login enforcement named $POLICY. Apply vault-config first."
echo "mount accessor $ACCESSOR, TOTP method $METHOD_ID, enforcement $POLICY: present"

step "Setting the password for $USERNAME"
read -rsp "New password (16 characters or more): " pw1; echo
read -rsp "Same password again: " pw2; echo
[ "$pw1" = "$pw2" ] || die "the two passwords differ. Nothing was written."
[ "${#pw1}" -ge 16 ] || die "the password is shorter than 16 characters. Nothing was written."
# password=- reads the value from stdin, so it never appears in argv or `ps`.
printf '%s' "$pw1" | vault write "auth/$MOUNT/users/$USERNAME" password=- \
  token_policies="$POLICY" token_ttl=1h token_max_ttl=1h token_explicit_max_ttl=1h \
  token_bound_cidrs="$BOUND_CIDR" token_type=service >/dev/null
unset pw1 pw2

step "Linking $USERNAME to the $ENTITY entity"
ENTITY_ID="$(vault read -format=json "identity/entity/name/$ENTITY" 2>/dev/null | jq -r '.data.id // empty' || true)"
if [ -z "$ENTITY_ID" ]; then
  ENTITY_ID="$(vault write -format=json identity/entity name="$ENTITY" | jq -r '.data.id')"
fi
[ -n "$ENTITY_ID" ] || die "could not create or read the $ENTITY entity."
ALIAS_ID="$(vault write -format=json identity/lookup/entity alias_name="$USERNAME" \
  alias_mount_accessor="$ACCESSOR" 2>/dev/null | jq -r '.data.id // empty' || true)"
if [ -z "$ALIAS_ID" ]; then
  vault write identity/entity-alias name="$USERNAME" canonical_id="$ENTITY_ID" \
    mount_accessor="$ACCESSOR" >/dev/null
elif [ "$ALIAS_ID" != "$ENTITY_ID" ]; then
  die "$USERNAME on $MOUNT/ already belongs to entity $ALIAS_ID, not $ENTITY ($ENTITY_ID). Fix that by hand first."
fi
echo "entity $ENTITY_ID"

step "Enrolling the entity on the TOTP method"
if [ "$REENROL" = 1 ]; then
  vault write identity/mfa/method/totp/admin-destroy method_id="$METHOD_ID" \
    entity_id="$ENTITY_ID" >/dev/null
  echo "the old TOTP secret is destroyed"
fi
GEN="$(vault write -format=json identity/mfa/method/totp/admin-generate \
  method_id="$METHOD_ID" entity_id="$ENTITY_ID")" \
  || die "enrolment failed. If this entity is already enrolled, rerun with --reenrol."
QR_DIR="$(mktemp -d)"
trap 'rm -rf "$QR_DIR"' EXIT
printf '%s' "$GEN" | jq -r '.data.barcode' | base64 --decode >"$QR_DIR/totp.png"
unset GEN
[ -s "$QR_DIR/totp.png" ] || die "Vault returned no QR code."
open "$QR_DIR/totp.png" 2>/dev/null || echo "Open $QR_DIR/totp.png yourself."
read -rp "Scan the code into your authenticator app, then press Enter to delete it. "

step "Reading the user back"
vault read -format=json "auth/$MOUNT/users/$USERNAME" | jq -e --arg p "$POLICY" --arg c "$BOUND_CIDR" '
  .data.token_policies == [$p] and .data.token_ttl == 3600 and .data.token_max_ttl == 3600
  and .data.token_explicit_max_ttl == 3600 and .data.token_bound_cidrs == [$c]' >/dev/null \
  || die "the user's token settings did not read back as written."
echo "user $USERNAME: policy $POLICY, 1-hour token with a fixed 1-hour ceiling, bound to $BOUND_CIDR"
echo
echo "Done. On 247, as $USERNAME: vault-breakglass"
