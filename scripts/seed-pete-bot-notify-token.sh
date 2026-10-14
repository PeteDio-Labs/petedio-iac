#!/usr/bin/env bash
# seed-pete-bot-notify-token.sh — mint the bearer that opens pete-bot's POST /v1/notify,
# and store it in kv/services/pete-bot as notify_bearer_token (PET-584).
#
# WHY ITS OWN TOKEN. notify-pedro on claude-247 and codex-248 sends it, and every session
# user there gets a copy. pete-bot refuses it on /v1/alert, so a session can DM Pedro and
# cannot post a fake monitor alert. The script refuses a value equal to alert_bearer_token.
#
# WHY A PATCH. kv/services/pete-bot also holds the Discord token and the /update token.
# `vault kv patch` writes this one field and keeps the others as they are.
#
# THE ORDER, on a first seed and on a rotation:
#   1. this script
#   2. deploy pete-bot: a merge to its main, or scripts/deploy-pete-bot.sh
#   3. scripts/deploy-claude-247.sh and scripts/deploy-codex-248.sh
# After a rotation, the hosts hold a token pete-bot refuses until step 3 finishes.
#
#   Vault token: $VAULT_TOKEN, else the macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM.
#   This script never prompts for it, and it never prints the bearer.
#
# Usage:
#   ./scripts/seed-pete-bot-notify-token.sh            # mint one when absent, else keep it
#   ./scripts/seed-pete-bot-notify-token.sh --rotate   # replace it
set -euo pipefail
umask 077

ROTATE=0
for arg in "$@"; do
  case "$arg" in
    --rotate) ROTATE=1 ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PATH_KV="kv/services/pete-bot"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$REPO_ROOT/environments/homelab/vault-ca.crt}"

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }

for t in vault python3; do command -v "$t" >/dev/null || die "$t not in PATH."; done

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

# field NAME, from the JSON in $SNAPSHOT. The value reaches python through the environment,
# never argv, and returns on stdout into a variable. Nothing here prints it.
field(){ SNAPSHOT="$SNAPSHOT" python3 -c '
import json, os, sys
try:
    d = json.loads(os.environ["SNAPSHOT"])["data"]["data"]
except Exception:
    d = {}
print(d.get(sys.argv[1], ""))' "$1"; }
names(){ SNAPSHOT="$SNAPSHOT" python3 -c '
import json, os
print(" ".join(sorted(json.loads(os.environ["SNAPSHOT"])["data"]["data"])))'; }

step "Read $PATH_KV"
SNAPSHOT="$(vault kv get -format=json "$PATH_KV" 2>/dev/null)" \
  || die "$PATH_KV is absent or unreadable. Run scripts/seed-pete-bot-vault.sh first."
BEFORE="$(names)"
ALERT="$(field alert_bearer_token)"
CURRENT="$(field notify_bearer_token)"
[ -n "$ALERT" ] || die "$PATH_KV has no alert_bearer_token. Run scripts/seed-pete-bot-vault.sh first."
echo "  fields: $BEFORE"

if [ -n "$CURRENT" ] && [ "$ROTATE" = "0" ]; then
  [ "$CURRENT" != "$ALERT" ] \
    || die "notify_bearer_token equals alert_bearer_token. Run this script with --rotate."
  echo "  notify_bearer_token: present, ${#CURRENT} characters. Kept (--rotate replaces it)."
  unset CURRENT ALERT SNAPSHOT
  exit 0
fi

step "Mint and write notify_bearer_token"
NEW="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
[ "$NEW" != "$ALERT" ] && [ "$NEW" != "$CURRENT" ] || die "the minted token repeats a stored one. Run this again."
# key=- reads the value from stdin, so it never reaches argv.
printf '%s' "$NEW" | vault kv patch "$PATH_KV" notify_bearer_token=- >/dev/null \
  || die "vault kv patch failed for $PATH_KV."

step "Verify, by reading it back"
SNAPSHOT="$(vault kv get -format=json "$PATH_KV")"
[ "$(field notify_bearer_token)" = "$NEW" ] || die "the read-back does not match the write."
[ "$(field alert_bearer_token)" = "$ALERT" ] || die "the patch changed alert_bearer_token."
AFTER="$(names)"
for f in $BEFORE; do
  case " $AFTER " in *" $f "*) ;; *) die "the patch dropped the field $f." ;; esac
done
echo "  notify_bearer_token: ${#NEW} characters, not the alert bearer"
echo "  fields: $AFTER"
unset NEW CURRENT ALERT SNAPSHOT

step "Done"
cat <<'NOTE'
  Next, in this order:
    1. Deploy pete-bot: merge to its main, or run scripts/deploy-pete-bot.sh.
    2. ./scripts/deploy-claude-247.sh
    3. ./scripts/deploy-codex-248.sh
  Each host deploy proves every copy with `notify-pedro --check`, which sends no DM.
NOTE
