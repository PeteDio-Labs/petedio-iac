#!/usr/bin/env bash
# seed-aws-watchdog-vault.sh — store the off-site watchdog's secrets in kv/services/aws-watchdog
# (PET-722):
#
#   aws_access_key_id, aws_secret_access_key   the petedio-terraform-watchdog IAM user
#   discord_webhook_url                        a Discord channel webhook for the AWS path
#   heartbeat_secret                           generated here, 48 hex characters
#   heartbeat_url                              the Lambda function URL (second run, --heartbeat-url)
#
# THE ORDER:
#   1. this script, with no argument                 (before the first terraform apply)
#   2. terraform apply in environments/offsite-watchdog (see its README)
#   3. this script with --heartbeat-url              (pastes the URL the apply printed)
#   4. scripts/deploy-lab-watchdog.sh                (lands the heartbeat on claude-247)
#
# Each value comes from a hidden prompt and never reaches argv or the screen. The script writes
# through a JSON file in a 0700 temporary directory that it deletes on exit. It keeps a heartbeat
# secret that already exists, because rotating it breaks the heartbeat until step 4 repeats.
#
#   Vault token: $VAULT_TOKEN, else the macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM.
#
# Usage:
#   ./scripts/seed-aws-watchdog-vault.sh
#   ./scripts/seed-aws-watchdog-vault.sh --heartbeat-url
set -euo pipefail
umask 077

MODE=keys
case "${1:-}" in
  "") ;;
  --heartbeat-url) MODE=url ;;
  -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
  *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PATH_KV="kv/services/aws-watchdog"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$REPO_ROOT/environments/homelab/vault-ca.crt}"

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }

for t in vault jq openssl; do command -v "$t" >/dev/null || die "$t not in PATH."; done
[ -t 0 ] || die "no terminal for the prompts. Run this in a terminal."

step "Vault"
if [ -z "${VAULT_TOKEN:-}" ] && command -v security >/dev/null; then
  VAULT_TOKEN="$(security find-generic-password -s "$VAULT_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null || true)"
fi
[ -n "${VAULT_TOKEN:-}" ] \
  || die "no VAULT_TOKEN and no Keychain item '$VAULT_TOKEN_KEYCHAIN_ITEM'. Export VAULT_TOKEN, then run this again."
export VAULT_TOKEN
vault token lookup >/dev/null 2>&1 \
  || die "the Vault token is invalid, or Vault is sealed. Run scripts/pet-secrets doctor."
echo "  reachable, and the token is valid"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
EXISTING="$(vault kv get -format=json "$PATH_KV" 2>/dev/null | jq -c '.data.data' 2>/dev/null || true)"
[ -n "$EXISTING" ] && [ "$EXISTING" != "null" ] || EXISTING='{}'
have(){ printf '%s' "$EXISTING" | jq -e --arg k "$1" '.[$k] // empty | length > 0' >/dev/null 2>&1; }

if [ "$MODE" = url ]; then
  step "Heartbeat URL"
  have aws_access_key_id || die "$PATH_KV has no keys yet. Run this script with no argument first."
  read -rp "  Function URL from the terraform output (https://...lambda-url...on.aws/): " URL
  case "$URL" in
    https://*.lambda-url.*.on.aws/*) ;;
    *) die "that is not a Lambda function URL." ;;
  esac
  printf '%s' "$EXISTING" | jq --arg u "$URL" '. + {heartbeat_url: $u}' > "$TMP/data.json"
else
  step "AWS keys and Discord webhook"
  read -rsp "  AWS access key ID for petedio-terraform-watchdog (hidden): " KID; echo
  read -rsp "  AWS secret access key (hidden): " KSECRET; echo
  read -rsp "  Discord webhook URL for the AWS path (hidden): " HOOK; echo
  case "$KID" in AKIA*|ASIA*) ;; *) die "that is not an AWS access key ID (AKIA...)." ;; esac
  [ "${#KSECRET}" -ge 30 ] || die "that secret key is too short."
  case "$HOOK" in
    https://discord.com/api/webhooks/*/*|https://discordapp.com/api/webhooks/*/*) ;;
    *) die "that is not a Discord webhook URL." ;;
  esac
  if have heartbeat_secret; then
    echo "  heartbeat_secret: kept"
    BEAT="$(printf '%s' "$EXISTING" | jq -r '.heartbeat_secret')"
  else
    BEAT="$(openssl rand -hex 24)"
    echo "  heartbeat_secret: generated"
  fi
  # The stored record holds the old secrets, so it reaches jq as a file, never as an argument.
  printf '%s' "$EXISTING" > "$TMP/old.json"
  K="$KID" S="$KSECRET" W="$HOOK" B="$BEAT" jq -n --slurpfile old "$TMP/old.json" \
    '$old[0] + {aws_access_key_id: env.K, aws_secret_access_key: env.S,
                discord_webhook_url: env.W, heartbeat_secret: env.B}' > "$TMP/data.json"
  unset KID KSECRET HOOK BEAT
fi

step "Writing $PATH_KV"
vault kv put "$PATH_KV" @"$TMP/data.json" >/dev/null
for f in aws_access_key_id aws_secret_access_key discord_webhook_url heartbeat_secret; do
  GOT="$(vault kv get -field="$f" "$PATH_KV" 2>/dev/null || true)"
  [ -n "$GOT" ] && echo "  $f: stored (${#GOT} characters)" || echo "  $f: not stored yet"
done
