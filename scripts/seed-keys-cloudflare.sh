#!/usr/bin/env bash
# seed-keys-cloudflare.sh — put the Cloudflare API token that .github/workflows/keys.yml uses into
# Vault at kv/services/keys-cloudflare, with the account id it works on.
#
# ⚠ PEDRO RUNS THIS, on the Mac with his own Vault login (PET-511). No session runs it.
#
# WHAT THE TOKEN MAY DO. Create it in the Cloudflare dashboard, My Profile > API Tokens > Create
# Custom Token, with exactly one permission: Account > Access: Service Tokens > Edit, on the one
# account. Nothing else: no zone, DNS, tunnel or Access app permission. keys.yml creates,
# rotates and deletes agent-* service tokens with it, and nothing more.
#
# WHAT THIS CHECKS BEFORE IT WRITES:
#   1. Cloudflare says the token is active (/user/tokens/verify).
#   2. The token sees exactly one account, and can list that account's service tokens.
#   3. The token is not the Terraform token at kv/iac/cloudflare.
#
# WHERE THE TOKEN COMES FROM. The clipboard: copy it from the dashboard, then run this. The
# script clears the clipboard once Vault holds the token. The token never reaches argv, the
# terminal or a transcript: curl reads its header from stdin.
#
#   Vault token: $VAULT_TOKEN, else the macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM.
#
# Usage: ./scripts/seed-keys-cloudflare.sh
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"
VAULT_PATH="kv/services/keys-cloudflare"
TF_VAULT_PATH="kv/iac/cloudflare"
CF_API="https://api.cloudflare.com/client/v4"

die()  { printf '\033[31mERROR\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

case "${1:-}" in -h|--help) sed -n '2,24p' "$0"; exit 0 ;; esac
for t in vault curl jq security pbpaste pbcopy; do command -v "$t" >/dev/null || die "$t not in PATH"; done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cf_get() {  # <token file> <path> <out file>; prints the HTTP status
  printf 'Authorization: Bearer %s\n' "$(cat "$1")" | curl -sS --max-time 20 -o "$3" -w '%{http_code}' \
    -H @- "$CF_API$2"
}

step "Reading the token from the clipboard"
pbpaste | tr -d '[:space:]' > "$TMP/key"
LEN="$(wc -c < "$TMP/key" | tr -d ' ')"
[ "$LEN" -ge 30 ] || die "The clipboard holds $LEN characters. Copy the token from the Cloudflare dashboard, and run this again."
grep -q '^[A-Za-z0-9_-]*$' "$TMP/key" || die "The token holds characters outside [A-Za-z0-9_-]. Copy it again."
echo "  $LEN characters, no whitespace."

step "Asking Cloudflare whether the token is active"
CODE="$(cf_get "$TMP/key" /user/tokens/verify "$TMP/verify.json")" || die "Cannot reach $CF_API."
[ "$CODE" = 200 ] && [ "$(jq -r '.result.status // empty' "$TMP/verify.json")" = active ] \
  || die "Cloudflare answered /user/tokens/verify with HTTP $CODE. The token is wrong, revoked or expired."
echo "  active."

step "Finding the one account it works on"
CODE="$(cf_get "$TMP/key" "/accounts?per_page=50" "$TMP/accounts.json")" || die "Cannot reach $CF_API."
[ "$CODE" = 200 ] || die "Cloudflare answered /accounts with HTTP $CODE."
N="$(jq '.result | length' "$TMP/accounts.json")"
[ "$N" = 1 ] || die "The token sees $N accounts. Scope it to the one account, and run this again."
ACCOUNT_ID="$(jq -r '.result[0].id' "$TMP/accounts.json")"
printf '%s' "$ACCOUNT_ID" | grep -Eq '^[0-9a-f]{32}$' || die "The account id is not 32 hex characters."
echo "  account $ACCOUNT_ID ($(jq -r '.result[0].name' "$TMP/accounts.json"))."

step "Checking it can list Access service tokens"
CODE="$(cf_get "$TMP/key" "/accounts/$ACCOUNT_ID/access/service_tokens?per_page=1" "$TMP/st.json")" || die "Cannot reach $CF_API."
[ "$CODE" = 200 ] || die "Cloudflare answered the service-token list with HTTP $CODE.
  Give the token Account > Access: Service Tokens > Edit, and run this again."
echo "  it can."

step "Authenticating to Vault"
[ -f "$VAULT_CACERT" ] || die "VAULT_CACERT not found at '$VAULT_CACERT'. Run the script from the repo, or export VAULT_CACERT."
if [ -z "${VAULT_TOKEN:-}" ]; then
  VAULT_TOKEN="$(security find-generic-password -s "$VAULT_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null || true)"
fi
[ -n "${VAULT_TOKEN:-}" ] || die "No Vault token. Export VAULT_TOKEN, or store it in the Keychain item '$VAULT_TOKEN_KEYCHAIN_ITEM'."
export VAULT_TOKEN
vault token lookup >/dev/null 2>&1 || die "Vault rejected the token, or $VAULT_ADDR is unreachable.
  Run ./scripts/pet-secrets doctor to see whether Vault is sealed."

step "Checking this is not the Terraform token"
if vault kv get -field=api_token "$TF_VAULT_PATH" > "$TMP/tf" 2>/dev/null; then
  cmp -s "$TMP/key" <(tr -d '[:space:]' < "$TMP/tf") \
    && die "This is the Terraform token at $TF_VAULT_PATH. keys.yml needs its own, scoped to Access service tokens."
  echo "  it is a different token."
else
  echo "  could not read $TF_VAULT_PATH to compare; continuing, since the scope checks above passed."
fi
rm -f "$TMP/tf"

step "Writing $VAULT_PATH"
jq -n --rawfile key "$TMP/key" --arg account_id "$ACCOUNT_ID" \
  '{api_token: ($key | rtrimstr("\n")), account_id: $account_id}' \
  | vault kv put "$VAULT_PATH" - >/dev/null

step "Verifying by read-back (never printing the token)"
vault kv get -field=api_token "$VAULT_PATH" > "$TMP/back" 2>/dev/null || die "Could not read $VAULT_PATH back."
cmp -s "$TMP/key" <(tr -d '\n' < "$TMP/back") || die "The token read back from Vault differs from the one given."
[ "$(vault kv get -field=account_id "$VAULT_PATH")" = "$ACCOUNT_ID" ] || die "account_id read-back mismatch."
echo "  api_token matches, account_id=$ACCOUNT_ID."

printf '' | pbcopy
echo "  Cleared the clipboard."

step "Next"
cat <<TXT
  Dispatch .github/workflows/keys.yml with action=list to prove the keys-list role, then
  action=sync. Approve the sync's lab-write step after you read its plan.
TXT
