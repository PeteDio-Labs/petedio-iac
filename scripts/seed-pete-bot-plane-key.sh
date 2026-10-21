#!/usr/bin/env bash
# seed-pete-bot-plane-key.sh — give pete-bot a read-only Plane identity, as plane_api_key in
# kv/services/pete-bot (PET-701).
#
# WHAT READS IT. pete-bot's scheduled reports (Morning queue, Hanging audit, Stale PR sweep)
# list PET work items and the newest comment on a few. They write nothing, and the client
# issues GET requests only.
#
# WHOSE TOKEN. The `codex` Plane user's, copied from kv/services/codex-plane. That user is a
# Member on PET and is not Pedro, so a report never reads as Pedro and the token can be
# revoked without touching kv/services/plane. When PET-660 makes a dedicated user, store that
# user's token in Vault and run this script again with SOURCE_PATH set to its path.
#
# WHAT THIS CHECKS BEFORE IT WRITES
#   1. The source token answers /users/me, and its user is not the kv/services/plane user.
#   2. It can read project PET.
#
# WHY A PATCH. kv/services/pete-bot also holds the Discord token and the bearers.
# `vault kv patch` writes this one field and keeps the others, and the read-back proves it.
#
#   Vault token: $VAULT_TOKEN, else the macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM.
#   This script never prompts for it, and it never prints the token.
#
# THE ORDER: this script, then scripts/deploy-pete-bot.sh. The deploy sets REPORTS_MODE=on
# only when this field and the desk App both exist.
#
# Usage:
#   ./scripts/seed-pete-bot-plane-key.sh
#   SOURCE_PATH=kv/services/<other> ./scripts/seed-pete-bot-plane-key.sh
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$REPO_ROOT/environments/homelab/vault-ca.crt}"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"
SOURCE_PATH="${SOURCE_PATH:-kv/services/codex-plane}"
PEDRO_VAULT_PATH="kv/services/plane"
DEST_PATH="kv/services/pete-bot"
PLANE_API="${PLANE_API:-http://192.168.50.235:8080/api/v1}"
WORKSPACE="petedio"
PET_PROJECT_ID="2b962587-cfc8-404d-bbfc-d57c3a60e07f"

die()  { printf '\033[31mERROR\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

for arg in "$@"; do
  case "$arg" in
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) die "unknown argument: $arg" ;;
  esac
done
for t in vault curl jq; do command -v "$t" >/dev/null || die "$t not in PATH"; done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The key reaches curl on stdin as a header, never in argv.
plane_get() {  # <key file> <path> <out file>; prints the HTTP status
  printf 'X-API-Key: %s\n' "$(cat "$1")" | curl -sS --max-time 20 -o "$3" -w '%{http_code}' \
    -H @- "$PLANE_API$2"
}

step "Vault"
if [ -z "${VAULT_TOKEN:-}" ] && command -v security >/dev/null; then
  VAULT_TOKEN="$(security find-generic-password -s "$VAULT_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null || true)"
fi
[ -n "${VAULT_TOKEN:-}" ] \
  || die "no VAULT_TOKEN and no Keychain item '$VAULT_TOKEN_KEYCHAIN_ITEM'. Export VAULT_TOKEN, then run this again."
export VAULT_TOKEN
vault token lookup >/dev/null 2>&1 || die "the Vault token is invalid, or Vault is sealed. Run scripts/pet-secrets doctor."
echo "  reachable, and the token is valid"

step "Reading the source token at $SOURCE_PATH"
vault kv get -field=api_key "$SOURCE_PATH" 2>/dev/null | tr -d '[:space:]' > "$TMP/key" \
  || die "cannot read api_key at $SOURCE_PATH. Run scripts/pet-secrets doctor."
LEN="$(wc -c < "$TMP/key" | tr -d ' ')"
[ "$LEN" -ge 20 ] || die "the token at $SOURCE_PATH is $LEN characters, which is not a Plane token."
grep -q '^[A-Za-z0-9_-]*$' "$TMP/key" || die "the token at $SOURCE_PATH holds characters outside [A-Za-z0-9_-]."
echo "  $LEN characters"

step "Asking Plane whose token this is"
CODE="$(plane_get "$TMP/key" /users/me/ "$TMP/me.json")" || die "cannot reach $PLANE_API."
[ "$CODE" = 200 ] || die "Plane answered /users/me with HTTP $CODE. The token is wrong, revoked or expired."
GOT_ID="$(jq -r '.id // empty' "$TMP/me.json")"
GOT_EMAIL="$(jq -r '.email // empty' "$TMP/me.json")"
[ -n "$GOT_ID" ] || die "Plane's /users/me answer holds no user id."
echo "  user $GOT_EMAIL, id $GOT_ID"

step "Checking this is not Pedro's token"
vault kv get -field=api_key "$PEDRO_VAULT_PATH" 2>/dev/null | tr -d '[:space:]' > "$TMP/pedro" \
  || die "cannot read $PEDRO_VAULT_PATH to compare."
CODE="$(plane_get "$TMP/pedro" /users/me/ "$TMP/pedro.json")" || die "cannot reach $PLANE_API."
rm -f "$TMP/pedro"
[ "$CODE" = 200 ] || die "Plane answered /users/me for $PEDRO_VAULT_PATH with HTTP $CODE, so the comparison cannot run."
PEDRO_ID="$(jq -r '.id // empty' "$TMP/pedro.json")"
[ -n "$PEDRO_ID" ] && [ "$PEDRO_ID" != "$GOT_ID" ] \
  || die "the source token's user is the $PEDRO_VAULT_PATH user. Reports must not read as Pedro."
echo "  source user $GOT_ID, $PEDRO_VAULT_PATH user $PEDRO_ID"

step "Checking that the token can read project PET"
CODE="$(plane_get "$TMP/key" "/workspaces/$WORKSPACE/projects/$PET_PROJECT_ID/work-items/?per_page=1" "$TMP/items.json")" \
  || die "cannot reach $PLANE_API."
[ "$CODE" = 200 ] || die "Plane answered the PET work-item list with HTTP $CODE."
TOTAL="$(jq -r '.total_count // empty' "$TMP/items.json")"
[ -n "$TOTAL" ] && [ "$TOTAL" -gt 0 ] || die "the PET work-item list reports no total or zero items, so a report would read an empty board."
echo "  $TOTAL work items readable"

step "Writing plane_api_key to $DEST_PATH"
BEFORE="$(vault kv get -format=json "$DEST_PATH" 2>/dev/null | jq -r '.data.data | keys | join(" ")')" \
  || die "cannot read $DEST_PATH. Run scripts/seed-pete-bot-vault.sh first."
[ -n "$BEFORE" ] || die "$DEST_PATH is empty."
# key=- reads the value from stdin, so it never reaches argv.
vault kv patch "$DEST_PATH" plane_api_key=- < "$TMP/key" >/dev/null || die "vault kv patch failed for $DEST_PATH."

step "Verifying by read-back"
vault kv get -field=plane_api_key "$DEST_PATH" 2>/dev/null | tr -d '[:space:]' > "$TMP/back" || die "cannot read $DEST_PATH back."
cmp -s "$TMP/key" "$TMP/back" || die "the value read back differs from the one written."
AFTER="$(vault kv get -format=json "$DEST_PATH" | jq -r '.data.data | keys | join(" ")')"
for f in $BEFORE; do
  case " $AFTER " in *" $f "*) ;; *) die "the patch dropped the field $f." ;; esac
done
echo "  plane_api_key matches; fields before: $BEFORE"
echo "                         fields after:  $AFTER"

step "Next"
cat <<'TXT'
  Run scripts/deploy-pete-bot.sh. With plane_api_key present it turns the reports on.
  Then, in Discord, run /report which:morning and compare it with the routine's DM.
  To rotate, create a new token as the Plane user, update the source path, and run this again.
TXT
