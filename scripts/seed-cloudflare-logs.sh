#!/usr/bin/env bash
# seed-cloudflare-logs.sh — put a read-only Cloudflare token for Access authentication logs into
# Vault at kv/services/cloudflare-logs, with the account id it works on. A thread then reads the
# logs through .github/workflows/cf-access-logs.yml, to find out why a sign-in ended.
#
# ⚠ PEDRO RUNS THIS, on the Mac with his own Vault login (PET-511). No session runs it.
#
# ORDER. 1) Merge the PR that adds vault-config/cf-logs.tf, then run scripts/apply-vault-config.sh
# (the gated apply cannot write the cf-logs-read names). 2) Run this script. 3) Dispatch
# cf-access-logs.yml. Step 1 may come second: the role only matters when the workflow runs.
#
# WHAT THE TOKEN MAY DO. Create it in the Cloudflare dashboard, My Profile > API Tokens > Create
# Custom Token, with exactly one permission: Account > Access: Audit Logs > Read, on the one
# account. Nothing else: no edit permission, no zone, DNS, tunnel, Access app or service-token
# permission. It reads sign-in records and changes nothing.
#
# WHAT THIS CHECKS BEFORE IT WRITES:
#   1. Cloudflare says the token is active (/user/tokens/verify).
#   2. The token can read the account's Access authentication logs.
#   2a. It cannot read zones, tunnels, Access apps or service tokens. This probes four likely
#       mistakes; it cannot prove the token holds no other permission.
#   3. The token is not the Terraform token at kv/iac/cloudflare, or the keys.yml token.
#   4. The path is absent, or you pass --rotate. The write uses check-and-set.
#
# WHERE THE TOKEN COMES FROM. The clipboard: copy it from the dashboard, then run this. The
# script clears the clipboard once Vault holds the token. The token never reaches argv, the
# terminal or a transcript: curl reads its header from stdin.
#
#   Vault token: $VAULT_TOKEN, else the macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM.
#   Account id: field account_id of kv/iac/cloudflare, else $CF_ACCOUNT_ID.
#
# Usage: ./scripts/seed-cloudflare-logs.sh [--rotate]
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"
VAULT_PATH="kv/services/cloudflare-logs"
TF_VAULT_PATH="kv/iac/cloudflare"
KEYS_VAULT_PATH="kv/services/keys-cloudflare"
CF_API="https://api.cloudflare.com/client/v4"
ROTATE=0

die()  { printf '\033[31mERROR\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

case "${1:-}" in
  -h|--help) sed -n '2,34p' "$0"; exit 0 ;;
  --rotate) ROTATE=1 ;;
  "") ;;
  *) die "Unknown argument '$1'. Usage: $0 [--rotate]" ;;
esac
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

step "Authenticating to Vault"
[ -f "$VAULT_CACERT" ] || die "VAULT_CACERT not found at '$VAULT_CACERT'. Run the script from the repo, or export VAULT_CACERT."
if [ -z "${VAULT_TOKEN:-}" ]; then
  VAULT_TOKEN="$(security find-generic-password -s "$VAULT_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null || true)"
fi
[ -n "${VAULT_TOKEN:-}" ] || die "No Vault token. Export VAULT_TOKEN, or store it in the Keychain item '$VAULT_TOKEN_KEYCHAIN_ITEM'."
export VAULT_TOKEN
vault token lookup >/dev/null 2>&1 || die "Vault rejected the token, or $VAULT_ADDR is unreachable.
  Run ./scripts/pet-secrets doctor to see whether Vault is sealed."

step "Reading the account id from $TF_VAULT_PATH"
# The account id is not secret, and kv/iac/cloudflare already holds it for Terraform. Reading
# it here means the token needs no account-read permission: an Access: Service Tokens token
# sees 0 accounts at /accounts (Pedro's Mac run, 2026-11-12). The service-token list below
# proves the token works on this account.
ACCOUNT_ID="${CF_ACCOUNT_ID:-$(vault kv get -field=account_id "$TF_VAULT_PATH" 2>/dev/null || true)}"
printf '%s' "$ACCOUNT_ID" | grep -Eq '^[0-9a-f]{32}$' \
  || die "No 32-hex account_id at $TF_VAULT_PATH. Export CF_ACCOUNT_ID from the dashboard URL, and run this again."
echo "  account $ACCOUNT_ID."

step "Checking it can read Access authentication logs"
CODE="$(cf_get "$TMP/key" "/accounts/$ACCOUNT_ID/access/logs/access_requests?limit=1" "$TMP/logs.json")" || die "Cannot reach $CF_API."
[ "$CODE" = 200 ] && [ "$(jq -r '.success // empty' "$TMP/logs.json")" = true ] || die "Cloudflare answered the access log read with HTTP $CODE.
  Give the token Account > Access: Audit Logs > Read, on the account in $TF_VAULT_PATH, and run this again."
echo "  it can."

step "Checking it can do nothing else it might have been given by mistake"
# Cloudflare cannot list a token's own permissions without API Tokens Read, so this probes
# three likely mistakes instead: zones, tunnels and Access apps. A pass does not prove the token
# holds no other permission; check the dashboard's summary.
#
# A token without the permission gets either a refusal or HTTP 200 with an empty list:
# Cloudflare answered /cfd_tunnel with 200 and no result for Pedro's Service Tokens-only token
# (2026-11-12). This account has a zone, a tunnel and Access apps, so a token that can read any
# of them gets a non-empty list. That is the only verdict that fails.
probe() {  # <label> <path>
  local code n
  code="$(cf_get "$TMP/key" "$2" "$TMP/p.json")" || die "Cannot reach $CF_API."
  case "$code" in
    200)
      # Count only a real array: jq gives length 0 for null, {} and "", which would pass.
      n="$(jq -e '.result | if type == "array" then length else error("no list") end' "$TMP/p.json" 2>/dev/null)" \
        || die "Cloudflare answered $1 with HTTP 200 but no result list; cannot tell what the token reads."
      case "$n" in
        0) echo "  $1: empty, so not readable." ;;
        *) die "The token can read $1 ($n seen). Give it only Account > Access: Audit Logs > Read." ;;
      esac ;;
    4??) echo "  $1: refused (HTTP $code)." ;;
    *) die "Cloudflare answered $1 with HTTP $code; cannot tell what the token reads." ;;
  esac
}
probe zones "/zones?per_page=1"
probe tunnels "/accounts/$ACCOUNT_ID/cfd_tunnel?per_page=1"
probe "Access apps" "/accounts/$ACCOUNT_ID/access/apps?per_page=1"
probe "service tokens" "/accounts/$ACCOUNT_ID/access/service_tokens?per_page=1"
echo "  zones, tunnels, Access apps and service tokens are not readable."

step "Checking this is not another token Vault already holds"
for pair in "$TF_VAULT_PATH:api_token" "$KEYS_VAULT_PATH:api_token"; do
  P="${pair%%:*}"; F="${pair##*:}"
  if vault kv get -field="$F" "$P" > "$TMP/other" 2>/dev/null; then
    cmp -s "$TMP/key" <(tr -d '[:space:]' < "$TMP/other") \
      && die "This is the token at $P. The logs token needs its own, with the Audit Logs Read permission only."
    echo "  differs from $P."
  else
    echo "  could not read $P to compare; continuing, since the scope checks above passed."
  fi
  rm -f "$TMP/other"
done

step "Proving the path state before writing"
# `vault kv get` exits 2 for an absent path and for a 403, so read the metadata and test the message.
VERSION=0
if vault kv get -format=json "$VAULT_PATH" > "$TMP/cur.json" 2>"$TMP/cur.err"; then
  [ "$(jq -r '.data.data // empty | type' "$TMP/cur.json")" = object ] || die "The current version of $VAULT_PATH is soft-deleted. Undelete or destroy it first."
  VERSION="$(jq -r '.data.metadata.version' "$TMP/cur.json")"
  [ "$ROTATE" = 1 ] || { echo "  $VAULT_PATH exists at version $VERSION. Pass --rotate to replace the token. Nothing written."; exit 0; }
elif vault kv metadata get "$VAULT_PATH" >/dev/null 2>"$TMP/meta.err"; then
  die "This Vault token sees $VAULT_PATH but cannot read its data. Use a token with read on kv/data/services/cloudflare-logs."
elif grep -q '^No value found at ' "$TMP/meta.err"; then
  echo "  $VAULT_PATH is absent."
else
  die "Vault refused or failed the read of $VAULT_PATH: $(head -c 200 "$TMP/meta.err")"
fi

step "Writing $VAULT_PATH (check-and-set, version $VERSION)"
jq -n --rawfile key "$TMP/key" --arg account_id "$ACCOUNT_ID" \
  '{api_token: ($key | rtrimstr("\n")), account_id: $account_id}' \
  | vault kv put -cas="$VERSION" "$VAULT_PATH" - >/dev/null

step "Verifying by read-back (never printing the token)"
vault kv get -field=api_token "$VAULT_PATH" > "$TMP/back" 2>/dev/null || die "Could not read $VAULT_PATH back."
cmp -s "$TMP/key" <(tr -d '\n' < "$TMP/back") || die "The token read back from Vault differs from the one given."
[ "$(vault kv get -field=account_id "$VAULT_PATH")" = "$ACCOUNT_ID" ] || die "account_id read-back mismatch."
echo "  api_token matches ($LEN characters), account_id=$ACCOUNT_ID, fields: api_token, account_id."

printf '' | pbcopy
echo "  Cleared the clipboard."

step "Next"
cat <<TXT
  Dispatch .github/workflows/cf-access-logs.yml (a thread does this), after scripts/apply-vault-config.sh
  has created the cf-logs-read role. Report: path $VAULT_PATH, new version $((VERSION + 1)), fields
  api_token ($LEN characters) and account_id. Never paste the token.
TXT
