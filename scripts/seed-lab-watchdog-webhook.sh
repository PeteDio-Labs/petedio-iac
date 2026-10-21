#!/usr/bin/env bash
# seed-lab-watchdog-webhook.sh — store the Discord webhook URL that lab-watchdog posts to, in
# kv/services/lab-watchdog as discord_webhook_url (PET-707).
#
# WHY A SEPARATE WEBHOOK. pete-bot is the first alert path, so the watchdog cannot post through
# it. A Discord channel webhook posts straight to Discord, and works when 237 is down. Create
# it in its own channel (Channel settings > Integrations > Webhooks > New Webhook), and do not
# reuse pete-bot's token.
#
# The URL is the credential. This script reads it from a hidden prompt, or from
# $LAB_WATCHDOG_WEBHOOK_URL, never from argv, and never prints it. It refuses anything that is
# not a discord.com webhook URL.
#
# THE ORDER:
#   1. this script
#   2. scripts/deploy-lab-watchdog.sh
#   3. on claude-247: sudo lab-watchdog --test   (posts one line to the channel)
#
#   Vault token: $VAULT_TOKEN, else the macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM.
#
# Usage:
#   ./scripts/seed-lab-watchdog-webhook.sh
set -euo pipefail
umask 077

case "${1:-}" in
  "") ;;
  -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
  *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PATH_KV="kv/services/lab-watchdog"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$REPO_ROOT/environments/homelab/vault-ca.crt}"

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }

command -v vault >/dev/null || die "vault not in PATH."

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

step "Webhook URL"
URL="${LAB_WATCHDOG_WEBHOOK_URL:-}"
if [ -z "$URL" ]; then
  [ -t 0 ] || die "no terminal for the prompt. Set LAB_WATCHDOG_WEBHOOK_URL, or run this in a terminal."
  read -rsp "  Discord webhook URL (hidden): " URL; echo
fi
case "$URL" in
  https://discord.com/api/webhooks/*/*|https://discordapp.com/api/webhooks/*/*) ;;
  *) die "that is not a Discord webhook URL (https://discord.com/api/webhooks/<id>/<token>)." ;;
esac

step "Writing $PATH_KV"
# kv put reads the value from stdin with `-`, so the URL never reaches argv.
printf '%s' "$URL" | vault kv put "$PATH_KV" discord_webhook_url=- >/dev/null
unset URL
GOT="$(vault kv get -field=discord_webhook_url "$PATH_KV" 2>/dev/null || true)"
[ -n "$GOT" ] || die "wrote $PATH_KV but read nothing back."
echo "  stored, and read back ${#GOT} characters"
