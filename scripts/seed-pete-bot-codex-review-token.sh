#!/usr/bin/env bash
# seed-pete-bot-codex-review-token.sh — mint the bearer that opens pete-bot's
# /v1/codex-review, and store it in kv/services/pete-bot as codex_review_bearer_token.
#
# WHY. A thread asks for a Codex second opinion through lab-agent's queue_codex_review tool.
# lab-agent calls pete-bot's /v1/codex-review with this bearer, and pete-bot queues the review
# with the merge desk's own Codex key. The same value is lab-agent's LAB_CODEX_REVIEW_TOKEN.
# Until it is seeded, the route refuses every request and lab-agent offers neither tool.
#
# WHY ITS OWN TOKEN. pete-bot refuses it on every other route, and refuses the alert and
# notify bearers here. The script refuses a value equal to either of them.
#
# WHY A PATCH. kv/services/pete-bot also holds the Discord token and the /update token.
# `vault kv patch` writes this one field and keeps the others as they are.
#
# THE ORDER, on a first seed and on a rotation:
#   1. this script
#   2. deploy pete-bot: a merge to its main, or scripts/deploy-pete-bot.sh. One deploy
#      renders the new value for both pete-bot and lab-agent, so there is no second host step.
#
#   Vault token: $VAULT_TOKEN, else the macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM.
#   This script never prompts for it, and it never prints the bearer.
#
# Usage:
#   ./scripts/seed-pete-bot-codex-review-token.sh            # mint one when absent, else keep it
#   ./scripts/seed-pete-bot-codex-review-token.sh --rotate   # replace it
set -euo pipefail
umask 077

ROTATE=0
for arg in "$@"; do
  case "$arg" in
    --rotate) ROTATE=1 ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
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
NOTIFY="$(field notify_bearer_token)"
CURRENT="$(field codex_review_bearer_token)"
[ -n "$ALERT" ] || die "$PATH_KV has no alert_bearer_token. Run scripts/seed-pete-bot-vault.sh first."
echo "  fields: $BEFORE"

if [ -n "$CURRENT" ] && [ "$ROTATE" = "0" ]; then
  [ "$CURRENT" != "$ALERT" ] && [ "$CURRENT" != "$NOTIFY" ] \
    || die "codex_review_bearer_token equals another route's bearer. Run this script with --rotate."
  echo "  codex_review_bearer_token: present, ${#CURRENT} characters. Kept (--rotate replaces it)."
  unset CURRENT ALERT NOTIFY SNAPSHOT
  exit 0
fi

step "Mint and write codex_review_bearer_token"
NEW="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
[ "$NEW" != "$ALERT" ] && [ "$NEW" != "$NOTIFY" ] && [ "$NEW" != "$CURRENT" ] || die "the minted token repeats a stored one. Run this again."
# key=- reads the value from stdin, so it never reaches argv.
printf '%s' "$NEW" | vault kv patch "$PATH_KV" codex_review_bearer_token=- >/dev/null \
  || die "vault kv patch failed for $PATH_KV."

step "Verify, by reading it back"
SNAPSHOT="$(vault kv get -format=json "$PATH_KV")"
[ "$(field codex_review_bearer_token)" = "$NEW" ] || die "the read-back does not match the write."
[ "$(field alert_bearer_token)" = "$ALERT" ] && [ "$(field notify_bearer_token)" = "$NOTIFY" ] || die "the patch changed another bearer."
AFTER="$(names)"
for f in $BEFORE; do
  case " $AFTER " in *" $f "*) ;; *) die "the patch dropped the field $f." ;; esac
done
echo "  codex_review_bearer_token: ${#NEW} characters, not the alert or notify bearer"
echo "  fields: $AFTER"
unset NEW CURRENT ALERT NOTIFY SNAPSHOT

step "Done"
cat <<'NOTE'
  Next: deploy pete-bot (a merge to its main, or scripts/deploy-pete-bot.sh).
  Proof: the lab MCP lists queue_codex_review and codex_review_status, and
  codex_review_status on an open desk-repo PR answers with a head SHA and a reviews list.
NOTE
