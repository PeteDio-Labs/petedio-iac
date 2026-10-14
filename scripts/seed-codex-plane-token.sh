#!/usr/bin/env bash
# seed-codex-plane-token.sh — put the `codex` Plane user's API token into Vault at
# kv/services/codex-plane, so Codex on codex-248 can read a work item and post a comment as
# itself (PET-553).
#
# WHY ITS OWN USER. A comment posted with Pedro's token reads as Pedro's. The `codex` user
# (pedelgadillo+codex@gmail.com, Member on PET) makes every Codex comment show Codex as its
# author, and its token can be revoked without touching kv/services/plane.
#
# WHAT THIS CHECKS BEFORE IT WRITES:
#   1. The token answers /users/me as the codex user's email, and nobody else's.
#   2. It is not the token at kv/services/plane, by Plane user id, read live.
#   3. The codex user can read project PET, so it is a member there.
#
# WHERE THE TOKEN COMES FROM. The clipboard, by default: copy it from Plane's API tokens
# page, then run this. The script clears the clipboard once Vault holds the token. To read a
# file instead, pass its path. The token never reaches argv, the terminal or the transcript.
#
#   Vault token: $VAULT_TOKEN, else the macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM.
#   This script never prompts for it.
#
# Usage:
#   ./scripts/seed-codex-plane-token.sh                 # read the clipboard
#   ./scripts/seed-codex-plane-token.sh <file> --shred  # read a file, then delete it
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"
VAULT_PATH="kv/services/codex-plane"
PEDRO_VAULT_PATH="kv/services/plane"
PLANE_API="${PLANE_API:-http://192.168.50.235:8080/api/v1}"
WORKSPACE="petedio"
PET_PROJECT_ID="2b962587-cfc8-404d-bbfc-d57c3a60e07f"
WANT_EMAIL="${WANT_EMAIL:-pedelgadillo+codex@gmail.com}"

die()  { printf '\033[31mERROR\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

SHRED=0
SRC=""
while [ $# -gt 0 ]; do
  case "$1" in
    --shred) SHRED=1 ;;
    -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
    *) SRC="$1" ;;
  esac
  shift
done
for t in vault curl jq security; do command -v "$t" >/dev/null || die "$t not in PATH"; done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ------------------------------------------------------------------ the token
step "Reading the token"
if [ -n "$SRC" ]; then
  [ -f "$SRC" ] || die "No such file: $SRC"
  tr -d '[:space:]' < "$SRC" > "$TMP/key"
else
  command -v pbpaste >/dev/null || die "pbpaste not found. Pass the token's file path instead."
  pbpaste | tr -d '[:space:]' > "$TMP/key"
fi
LEN="$(wc -c < "$TMP/key" | tr -d ' ')"
[ "$LEN" -ge 20 ] || die "The token is $LEN characters. Copy it from Plane's API tokens page, and run this again."
grep -q '^[A-Za-z0-9_-]*$' "$TMP/key" || die "The token holds characters outside [A-Za-z0-9_-]. Copy it again from Plane."
echo "  $LEN characters, no whitespace."

# The key reaches curl on stdin as a header, never in argv.
plane_get() {  # <key file> <path> <out file>; prints the HTTP status
  printf 'X-API-Key: %s\n' "$(cat "$1")" | curl -sS --max-time 20 -o "$3" -w '%{http_code}' \
    -H @- "$PLANE_API$2"
}

step "Asking Plane whose token this is"
CODE="$(plane_get "$TMP/key" /users/me/ "$TMP/me.json")" || die "Cannot reach $PLANE_API."
[ "$CODE" = 200 ] || die "Plane answered /users/me with HTTP $CODE. The token is wrong, revoked, or expired."
GOT_EMAIL="$(jq -r '.email // empty' "$TMP/me.json")"
GOT_ID="$(jq -r '.id // empty' "$TMP/me.json")"
GOT_NAME="$(jq -r '.display_name // empty' "$TMP/me.json")"
[ "$GOT_EMAIL" = "$WANT_EMAIL" ] || die "This token belongs to '$GOT_EMAIL', not $WANT_EMAIL.
  Sign in to Plane as the codex user, create the token there, and run this again."
echo "  user $GOT_NAME ($GOT_EMAIL), id $GOT_ID"

# ---------------------------------------------------------------------- vault
step "Authenticating to Vault"
[ -f "$VAULT_CACERT" ] || die "VAULT_CACERT not found at '$VAULT_CACERT'. Run the script from the repo, or export VAULT_CACERT."
if [ -z "${VAULT_TOKEN:-}" ]; then
  VAULT_TOKEN="$(security find-generic-password -s "$VAULT_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null || true)"
fi
[ -n "${VAULT_TOKEN:-}" ] || die "No Vault token. Export VAULT_TOKEN, or store it in the Keychain item '$VAULT_TOKEN_KEYCHAIN_ITEM'."
export VAULT_TOKEN
vault token lookup >/dev/null 2>&1 || die "Vault rejected the token, or $VAULT_ADDR is unreachable.
  Run ./scripts/pet-secrets doctor to see whether Vault is sealed."

step "Checking this is not Pedro's token"
vault kv get -field=api_key "$PEDRO_VAULT_PATH" > "$TMP/pedro" 2>/dev/null \
  || die "Could not read $PEDRO_VAULT_PATH to compare. Run ./scripts/pet-secrets doctor."
CODE="$(plane_get "$TMP/pedro" /users/me/ "$TMP/pedro.json")" || die "Cannot reach $PLANE_API."
rm -f "$TMP/pedro"
[ "$CODE" = 200 ] || die "Plane answered /users/me for $PEDRO_VAULT_PATH with HTTP $CODE, so the comparison cannot run."
PEDRO_ID="$(jq -r '.id // empty' "$TMP/pedro.json")"
[ -n "$PEDRO_ID" ] && [ "$PEDRO_ID" != "$GOT_ID" ] \
  || die "This token's user is the $PEDRO_VAULT_PATH user ($PEDRO_ID). The codex user needs its own."
echo "  codex is $GOT_ID; the $PEDRO_VAULT_PATH user is $PEDRO_ID."

step "Checking that codex can read project PET"
CODE="$(plane_get "$TMP/key" "/workspaces/$WORKSPACE/projects/$PET_PROJECT_ID/" "$TMP/proj.json")" \
  || die "Cannot reach $PLANE_API."
[ "$CODE" = 200 ] || die "Plane answered project PET with HTTP $CODE.
  Add codex to PET as a Member: http://192.168.50.235:8080/$WORKSPACE/projects/$PET_PROJECT_ID/settings/members"
echo "  PET is readable as codex: $(jq -r '.identifier // empty' "$TMP/proj.json")."

# ----------------------------------------------------------------- vault write
step "Writing $VAULT_PATH"
jq -n --rawfile key "$TMP/key" --arg user_id "$GOT_ID" --arg email "$GOT_EMAIL" \
  '{api_key: ($key | rtrimstr("\n")), user_id: $user_id, email: $email}' \
  | vault kv put "$VAULT_PATH" - >/dev/null

step "Verifying by read-back (never printing the token)"
vault kv get -field=api_key "$VAULT_PATH" > "$TMP/back" 2>/dev/null || die "Could not read $VAULT_PATH back."
cmp -s <(tr -d '\n' < "$TMP/key") <(tr -d '\n' < "$TMP/back") || die "The token read back from Vault differs from the one given."
[ "$(vault kv get -field=user_id "$VAULT_PATH")" = "$GOT_ID" ] || die "user_id read-back mismatch."
echo "  api_key matches, user_id=$GOT_ID, email=$GOT_EMAIL."

# -------------------------------------------------------------------- cleanup
if [ -z "$SRC" ]; then
  printf '' | pbcopy
  echo "  Cleared the clipboard."
elif [ "$SHRED" -eq 1 ]; then
  rm -P "$SRC" 2>/dev/null || rm -f "$SRC"
  echo "  $SRC removed."
else
  echo "  $SRC still holds the token. Delete it, or run this again with --shred."
fi

step "Next"
cat <<TXT
  To deliver the token to codex-248, run ./scripts/deploy-codex-248.sh.

  To rotate it, create a new token as codex, run this script, run the deploy, then delete
  the old token on Plane's API tokens page.
TXT
