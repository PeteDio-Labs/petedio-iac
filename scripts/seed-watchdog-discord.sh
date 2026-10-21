#!/usr/bin/env bash
# seed-watchdog-discord.sh — give both watchdogs the Discord bot credentials they post with
# (PET-728): the bot token and the id of Pedro's DM with the Lab-Agent app.
#
#   kv/services/lab-watchdog   discord_bot_token, discord_dm_channel_id   (the in-lab probe, PET-707)
#   kv/services/aws-watchdog   discord_bot_token, discord_dm_channel_id   (the AWS Lambda, PET-722)
#
# WHY A BOT AND NOT A WEBHOOK. A Discord webhook belongs to a server channel and cannot post into
# a DM. Both watchdogs post as the Lab-Agent app straight to discord.com, so the path still
# bypasses pete-bot on 237.
#
# THE TRADE-OFF. The token is pete-bot's, copied. Rotating it in the developer portal silences
# pete-bot and both watchdogs together, and the copy in SSM can act as the whole app. A second
# Discord app removes both risks: put its token and owner id in kv/services/pete-bot-watchdog
# (fields discord_token, owner_user_id) and run this script with PET_BOT_PATH set to that path.
#
# This script reads discord_token and owner_user_id from kv/services/pete-bot, opens the DM
# through Discord's API, and writes the two fields to both paths. It keeps every other field in
# those paths. No value reaches argv or the screen: Vault reads go to variables, the token
# reaches curl as a config line on stdin, and Vault takes the write from a 0700 temp file.
#
# THE ORDER:
#   1. this script
#   2. scripts/seed-aws-watchdog-vault.sh   (AWS keys), then the terraform apply
#   3. scripts/deploy-lab-watchdog.sh, then on claude-247: sudo lab-watchdog --test
#
#   Vault token: $VAULT_TOKEN, else the macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM.
#
# Usage:
#   ./scripts/seed-watchdog-discord.sh
set -euo pipefail
umask 077

case "${1:-}" in
  "") ;;
  -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
  *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_KV="${PET_BOT_PATH:-kv/services/pete-bot}"
TARGETS=(kv/services/lab-watchdog kv/services/aws-watchdog)
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$REPO_ROOT/environments/homelab/vault-ca.crt}"

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }

for t in vault jq curl; do command -v "$t" >/dev/null || die "$t not in PATH."; done

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

step "Reading the bot credentials from $SOURCE_KV"
BOT_TOKEN="$(vault kv get -field=discord_token "$SOURCE_KV" 2>/dev/null || true)"
OWNER_ID="$(vault kv get -field=owner_user_id "$SOURCE_KV" 2>/dev/null || true)"
[ -n "$BOT_TOKEN" ] || die "$SOURCE_KV has no discord_token."
case "$OWNER_ID" in ''|*[!0-9]*) die "$SOURCE_KV has no numeric owner_user_id." ;; esac
echo "  discord_token: read (${#BOT_TOKEN} characters), owner_user_id: read"

step "Opening the DM through Discord"
UA='DiscordBot (https://github.com/PeteDio-Labs/petedio-iac, 1)'
# The token goes to curl on stdin as a config line, never in argv where `ps` would show it.
REPLY="$(printf 'header = "Authorization: Bot %s"\n' "$BOT_TOKEN" \
  | curl -sS -f -m 15 -K - -A "$UA" -H 'Content-Type: application/json' \
      -d "{\"recipient_id\":\"$OWNER_ID\"}" https://discord.com/api/v10/users/@me/channels)" \
  || die "Discord refused the request. The token in $SOURCE_KV may be revoked or wrong."
CHANNEL_ID="$(printf '%s' "$REPLY" | jq -r '.id // empty')"
case "$CHANNEL_ID" in ''|*[!0-9]*) die "Discord's answer held no DM channel id." ;; esac
echo "  DM channel id: obtained (${#CHANNEL_ID} digits)"

step "Writing the two paths"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
T="$BOT_TOKEN" C="$CHANNEL_ID" jq -n '{discord_bot_token: env.T, discord_dm_channel_id: env.C}' > "$TMP/data.json"
unset BOT_TOKEN OWNER_ID REPLY
for path in "${TARGETS[@]}"; do
  # patch -method=rw merges into the record, so the AWS keys and heartbeat secret survive, and
  # creates the record when it does not exist yet.
  vault kv patch -method=rw "$path" @"$TMP/data.json" >/dev/null
  for f in discord_bot_token discord_dm_channel_id; do
    GOT="$(vault kv get -field="$f" "$path" 2>/dev/null || true)"
    [ -n "$GOT" ] || die "wrote $path but read no $f back."
    echo "  $path $f: stored (${#GOT} characters)"
  done
done
echo
echo "  Next: scripts/seed-aws-watchdog-vault.sh, then scripts/deploy-lab-watchdog.sh."
