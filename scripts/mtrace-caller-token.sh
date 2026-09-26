#!/usr/bin/env bash
# mtrace-caller-token.sh — create, rotate or revoke one caller's mtrace API token
# (PET-518).
#
# ⚠ NO CLAUDE SESSION RUNS THIS SCRIPT. Minting or revoking a live credential is the
# "place a credential by hand" line this repo's rules draw around Pedro: he runs this on
# the Mac with his own Vault login, the same way he runs scripts/mtrace-caller-token.sh
# create bobbert or revoke pete-bot from a work-item's plan, never a session relaying it
# on his behalf.
#
# mtrace's HTTP API used to gate on one shared MEDIA_CONTROL_TOKEN, minted by
# scripts/reseed-media-dash-vault.sh. PET-518 splits that into one token per caller —
# kv/services/media/dashboard field token_<name> — so a leaked or retiring caller costs
# one token, not every caller's access. The legacy field api_token still exists for
# pete-bot until `revoke pete-bot` drops it.
#
# Usage:
#   mtrace-caller-token.sh create <name>
#   mtrace-caller-token.sh rotate <name>
#   mtrace-caller-token.sh revoke <name>
#
# <name> matches ^[a-z0-9-]+$ and names the field token_<name>. create refuses when that
# field already exists; rotate requires that it does. revoke pete-bot also drops the
# legacy api_token field, since that field and token_pete-bot are the same caller.
#
# The token value never appears in argv, stdout, stderr, a file or under `set -x`: it is
# generated with openssl and piped to Vault on stdin. What IS printed: the field name, the
# resulting secret version, and next steps — never the token itself.
#
# After create or rotate, redeploy with scripts/deploy-media-dash.sh so mtrace picks up
# the new MEDIA_CONTROL_TOKENS. After create, hand the token to its caller yourself; this
# script never prints it:
#   vault kv get -field=token_<name> kv/services/media/dashboard | pbcopy
#
# No secrets printed. Vault token: $VAULT_TOKEN, else macOS Keychain $VAULT_TOKEN_KEYCHAIN_ITEM.
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"
SECRET_PATH="kv/services/media/dashboard"
NAME_RE='^[a-z0-9-]+$'

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
usage(){ printf 'Usage: %s create|rotate|revoke <name>\n' "$(basename "$0")" >&2; exit 1; }

[ $# -eq 2 ] || usage
ACTION="$1"
NAME="$2"
case "$ACTION" in
  create|rotate|revoke) ;;
  *) usage ;;
esac
[[ "$NAME" =~ $NAME_RE ]] || die "Name '$NAME' must match $NAME_RE."
FIELD="token_${NAME}"

for t in vault jq openssl; do command -v "$t" >/dev/null || die "$t not in PATH."; done

step "Resolving Vault token"
if [ -z "${VAULT_TOKEN:-}" ]; then
  VAULT_TOKEN="$(security find-generic-password -s "$VAULT_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null || true)"
fi
[ -n "${VAULT_TOKEN:-}" ] || { read -rsp "Vault token: " VAULT_TOKEN; echo; }
export VAULT_TOKEN
vault token lookup >/dev/null 2>&1 || die "Vault token invalid / Vault unreachable."

mtrace_create() {
  step "Checking $SECRET_PATH for $FIELD"
  local existing has_field
  existing="$(vault kv get -format=json "$SECRET_PATH" 2>/dev/null || echo '{}')"
  has_field="$(printf '%s' "$existing" | jq -r --arg f "$FIELD" '(.data.data // {}) | has($f)')"
  [ "$has_field" = "false" ] || die "$FIELD already exists at $SECRET_PATH. Use rotate to replace it."

  step "Minting and writing $FIELD"
  local result version
  # The token never touches argv: openssl writes it to a pipe, and vault reads that pipe
  # as the value for FIELD because the argument is "FIELD=-".
  result="$(openssl rand -hex 32 | vault kv patch -format=json "$SECRET_PATH" "${FIELD}=-")"
  version="$(printf '%s' "$result" | jq -r '.data.version')"

  echo "field: $FIELD"
  echo "version: $version"
  echo
  echo "Next:"
  echo "  1. Redeploy: scripts/deploy-media-dash.sh"
  echo "  2. Hand the token to '$NAME' yourself — this script never prints it:"
  echo "       vault kv get -field=$FIELD $SECRET_PATH | pbcopy"
}

mtrace_rotate() {
  step "Checking $SECRET_PATH for $FIELD"
  local existing has_field
  existing="$(vault kv get -format=json "$SECRET_PATH" 2>/dev/null)" || die "Could not read $SECRET_PATH."
  has_field="$(printf '%s' "$existing" | jq -r --arg f "$FIELD" '(.data.data // {}) | has($f)')"
  [ "$has_field" = "true" ] || die "$FIELD is not set at $SECRET_PATH. Use create instead."

  step "Minting and writing a fresh $FIELD"
  local result version
  result="$(openssl rand -hex 32 | vault kv patch -format=json "$SECRET_PATH" "${FIELD}=-")"
  version="$(printf '%s' "$result" | jq -r '.data.version')"

  echo "field: $FIELD"
  echo "version: $version"
  echo
  echo "Next: redeploy with scripts/deploy-media-dash.sh so mtrace picks up the new token."
}

mtrace_revoke() {
  step "Reading $SECRET_PATH"
  local existing version has_field has_legacy=0
  existing="$(vault kv get -format=json "$SECRET_PATH" 2>/dev/null)" || die "Could not read $SECRET_PATH."
  version="$(printf '%s' "$existing" | jq -r '.data.metadata.version')"
  if [ -z "$version" ] || [ "$version" = "null" ]; then
    die "Could not read the current version of $SECRET_PATH."
  fi
  has_field="$(printf '%s' "$existing" | jq -r --arg f "$FIELD" '(.data.data // {}) | has($f)')"

  # ⚠ pete-bot MAY HOLD ONLY THE LEGACY FIELD. Nothing ever required minting a dedicated
  # token_pete-bot — deploy-media-dash.sh maps the legacy api_token to caller "pete-bot"
  # on its own — so the first "revoke pete-bot" after PET-518 ships typically finds
  # api_token and no token_pete-bot at all. Treat either as something to revoke.
  local drop_legacy=0
  if [ "$NAME" = "pete-bot" ]; then
    has_legacy="$(printf '%s' "$existing" | jq -r '(.data.data // {}) | has("api_token")')"
    [ "$has_legacy" = "true" ] && drop_legacy=1
  fi
  if [ "$has_field" != "true" ] && [ "$drop_legacy" = "0" ]; then
    die "Neither $FIELD nor a legacy api_token is set at $SECRET_PATH. Nothing to revoke."
  fi

  step "Dropping $FIELD"
  local full_filter='.data.data | del(.[$f])'
  if [ "$drop_legacy" = "1" ]; then
    full_filter='.data.data | del(.[$f]) | del(.api_token)'
  fi

  # CAS on the version just read: if something else wrote to this path in between, the
  # write below fails rather than clobbering it. One jq call, reading the full get
  # response and emitting the flat field map (minus the dropped field(s)) that
  # `vault kv put -` expects on stdin.
  local result new_version
  result="$(printf '%s' "$existing" \
    | jq --arg f "$FIELD" "$full_filter" \
    | vault kv put -format=json -cas="$version" "$SECRET_PATH" -)"
  new_version="$(printf '%s' "$result" | jq -r '.data.version')"

  echo "field: $FIELD (revoked)"
  [ "$drop_legacy" = "1" ] && echo "field: api_token (revoked, legacy)"
  echo "version: $new_version"
  echo
  echo "Next: redeploy with scripts/deploy-media-dash.sh so mtrace drops '$NAME'."
}

case "$ACTION" in
  create) mtrace_create ;;
  rotate) mtrace_rotate ;;
  revoke) mtrace_revoke ;;
esac
