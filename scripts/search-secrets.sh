#!/usr/bin/env bash
# search-secrets.sh — mint and manage petedio-search's secrets at kv/services/search
# (PET-526).
#
# ⚠ NO CLAUDE SESSION RUNS THIS SCRIPT. Minting or revoking a live credential is the
# "place a credential by hand" line this repo's rules draw around Pedro. He runs it on the
# Mac with his own Vault login and his own `gh` login.
#
# Usage:
#   search-secrets.sh create <name>     mint caller <name>'s bearer token (token_<name>)
#   search-secrets.sh rotate <name>     replace it
#   search-secrets.sh revoke <name>     drop it
#   search-secrets.sh plane-key         store the Plane API key, read from stdin
#
# The first setup is three commands:
#   search-secrets.sh create claude
#   search-secrets.sh create bobbert
#   pbpaste | search-secrets.sh plane-key     (a Plane API key minted for this service)
#
# The service reads the vault through the petedio-workspace-mirror GitHub App, whose key
# scripts/seed-workspace-mirror-vault.sh stores. The org disallows deploy keys, so the
# PET-526 deploy-key action is gone (PET-542).
#
# Give the service its own Plane key rather than plane-sync's: Plane rate-limits each key
# to 120 calls a minute, and the first refresh spends most of that for several minutes.
#
# No value ever appears in argv, stdout, stderr or under `set -x`. Tokens go from openssl
# to Vault through a pipe. The script prints field names, secret versions and next steps.
#
# After any change, redeploy with scripts/deploy-search.sh. To hand a caller its token:
#   vault kv get -field=token_<name> kv/services/search | pbcopy
#
# Vault token: $VAULT_TOKEN, else macOS Keychain $VAULT_TOKEN_KEYCHAIN_ITEM. Never prompts.
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"
SECRET_PATH="kv/services/search"
NAME_RE='^[a-z0-9-]+$'

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
usage(){ printf 'Usage: %s create|rotate|revoke <name> | plane-key\n' "$(basename "$0")" >&2; exit 1; }

[ $# -ge 1 ] || usage
ACTION="$1"
case "$ACTION" in
  create|rotate|revoke)
    [ $# -eq 2 ] || usage
    NAME="$2"
    [[ "$NAME" =~ $NAME_RE ]] || die "Name '$NAME' must match $NAME_RE."
    FIELD="token_${NAME}"
    ;;
  plane-key) [ $# -eq 1 ] || usage ;;
  *) usage ;;
esac

for t in vault jq openssl; do command -v "$t" >/dev/null || die "$t not in PATH."; done

step "Resolving Vault token"
if [ -z "${VAULT_TOKEN:-}" ]; then
  VAULT_TOKEN="$(security find-generic-password -s "$VAULT_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null || true)"
fi
[ -n "${VAULT_TOKEN:-}" ] || die "no Vault token: set VAULT_TOKEN or add the Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM"
export VAULT_TOKEN
vault token lookup >/dev/null 2>&1 || die "Vault token invalid / Vault unreachable."

# The secret as JSON, or {} when the path does not exist yet.
EXISTING="$(vault kv get -format=json "$SECRET_PATH" 2>/dev/null || echo '{}')"
has_field(){ printf '%s' "$EXISTING" | jq -r --arg f "$1" '(.data.data // {}) | has($f)'; }
path_exists(){ printf '%s' "$EXISTING" | jq -e '.data.data' >/dev/null; }

# Writes FIELD=- from stdin, plus any extra FIELD=@file arguments. `vault kv patch` fails
# on a path that does not exist, so the first write uses put.
kv_write() {
  local verb=patch result
  path_exists || verb=put
  result="$(vault kv "$verb" -format=json "$SECRET_PATH" "$@")"
  printf '%s' "$result" | jq -r '.data.version'
}

search_mint() {
  # `tr -d '\n'`: Vault stores a "-" value verbatim, and openssl ends its output with a
  # newline, which would split SEARCH_TOKENS across two lines in the env file.
  openssl rand -hex 32 | tr -d '\n' | kv_write "${FIELD}=-"
}

search_create() {
  [ "$(has_field "$FIELD")" = "false" ] || die "$FIELD already exists at $SECRET_PATH. Use rotate to replace it."
  step "Minting $FIELD"
  echo "version: $(search_mint)"
  echo
  echo "Next:"
  echo "  1. Redeploy: scripts/deploy-search.sh"
  echo "  2. Hand the token to '$NAME' yourself. This script never prints it:"
  echo "       vault kv get -field=$FIELD $SECRET_PATH | pbcopy"
}

search_rotate() {
  [ "$(has_field "$FIELD")" = "true" ] || die "$FIELD is not set at $SECRET_PATH. Use create instead."
  step "Minting a fresh $FIELD"
  echo "version: $(search_mint)"
  echo
  echo "Next: redeploy with scripts/deploy-search.sh, then hand '$NAME' the new token."
}

search_revoke() {
  [ "$(has_field "$FIELD")" = "true" ] || die "$FIELD is not set at $SECRET_PATH. Nothing to revoke."
  local version result
  version="$(printf '%s' "$EXISTING" | jq -r '.data.metadata.version')"
  step "Dropping $FIELD"
  # CAS on the version just read, so a concurrent write fails this one instead of being
  # clobbered by it.
  result="$(printf '%s' "$EXISTING" \
    | jq --arg f "$FIELD" '.data.data | del(.[$f])' \
    | vault kv put -format=json -cas="$version" "$SECRET_PATH" -)"
  echo "version: $(printf '%s' "$result" | jq -r '.data.version')"
  echo
  echo "Next: redeploy with scripts/deploy-search.sh so the service drops '$NAME'."
}

search_plane_key() {
  [ ! -t 0 ] || die "pipe the key in: pbpaste | $(basename "$0") plane-key"
  step "Storing plane_api_key"
  local key
  key="$(tr -d '\r\n')"
  [[ "$key" =~ ^[A-Za-z0-9_-]+$ ]] || die "stdin is not a Plane API key (want [A-Za-z0-9_-]+)."
  echo "version: $(printf '%s' "$key" | kv_write "plane_api_key=-")"
  echo
  echo "Next: redeploy with scripts/deploy-search.sh."
}

case "$ACTION" in
  create) search_create ;;
  rotate) search_rotate ;;
  revoke) search_revoke ;;
  plane-key) search_plane_key ;;
esac
