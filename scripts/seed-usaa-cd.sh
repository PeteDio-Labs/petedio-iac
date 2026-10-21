#!/usr/bin/env bash
# seed-usaa-cd.sh — place the usaa-cd deploy's inputs in kv/services/usaa, so the deploy
# reads them without a wider grant (PET-695).
#
#   access_aud          the usaa_access_aud Terraform output. An identifier, not a secret.
#   notify_bearer_token copied from kv/services/pete-bot, where pete-bot owns it.
#   deploy_ssh_private_key / deploy_ssh_public_key  an ed25519 pair made for this app. The
#                       deploy connects to usaa-238 with it, so the usaa-cd role never reads
#                       the shared kv/iac/lxc-ssh key. An existing pair is kept. To replace
#                       it, run with --rotate-key, then ./scripts/deploy-usaa.sh.
#
# WHY A COPY. The usaa-cd policy reads kv/services/usaa and not kv/services/pete-bot. Vault
# cannot scope a read to one field, and the pete-bot path holds the Discord token and the
# desk App's key. Run this script again after you rotate pete-bot's notify token, or the
# app keeps sending the old one.
#
# HOW IT WRITES. `vault kv patch -cas=<version>` changes these fields and keeps the others.
# The values go to Vault on stdin, never on the command line. The script prints field names
# and lengths, never a value, and reads the fields back.
#
# THE ORDER:
#   1. apply environments/homelab/vault-config (the usaa-cd role and policy)
#   2. this script, run by Pedro
#   3. ./scripts/deploy-usaa.sh from the Mac, which installs the public key on usaa-238
#   4. merge the petedio-usaa deploy workflow
#
#   Vault token: $VAULT_TOKEN, else the macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM.
#
# Usage:
#   ./scripts/seed-usaa-cd.sh [--rotate-key]
set -euo pipefail
umask 077

case "${1:-}" in
  "") ROTATE=0 ;;
  --rotate-key) ROTATE=1 ;;
  -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
  *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"
DEST="kv/services/usaa"
SRC_PB="kv/services/pete-bot"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }
for t in vault terraform python3 ssh-keygen; do command -v "$t" >/dev/null || die "$t not in PATH."; done

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

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

step "Read the Access audience from Terraform state"
AWS_ACCESS_KEY_ID="$(vault kv get -field=access_key kv/iac/minio)"; export AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY="$(vault kv get -field=secret_key kv/iac/minio)"; export AWS_SECRET_ACCESS_KEY
[ -n "$AWS_ACCESS_KEY_ID" ] && [ -n "$AWS_SECRET_ACCESS_KEY" ] || die "could not read kv/iac/minio."
terraform -chdir="$HOMELAB" init -reconfigure -input=false >"$TMP/init.log" 2>&1 \
  || { tail -15 "$TMP/init.log"; die "terraform init failed."; }
AUD="$(terraform -chdir="$HOMELAB" output -raw usaa_access_aud 2>/dev/null || true)"
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
printf '%s' "$AUD" | grep -Eq '^[0-9a-f]{64}$' \
  || die "usaa_access_aud is empty or is not 64 lowercase hex characters."
echo "  access_aud: 64 characters"

step "Read notify_bearer_token from $SRC_PB"
NOTIFY="$(vault kv get -field=notify_bearer_token "$SRC_PB" 2>/dev/null || true)"
printf '%s' "$NOTIFY" | grep -Eq '^[A-Za-z0-9_-]+$' \
  || die "$SRC_PB has no notify_bearer_token, or it has characters the app's env file cannot hold."
echo "  notify_bearer_token: ${#NOTIFY} characters"

step "Read $DEST"
# Only "No value found" proves the path absent; any other failure stops the script.
if SNAP="$(vault kv get -format=json "$DEST" 2>/dev/null)"; then
  VERSION="$(SNAP="$SNAP" python3 -c 'import json,os; print(json.loads(os.environ["SNAP"])["data"]["metadata"]["version"])')" \
    || die "could not parse the read of $DEST."
elif ERR="$(vault kv metadata get "$DEST" 2>&1 >/dev/null)"; then
  die "$DEST has metadata, but the token cannot read its data."
else
  case "$ERR" in
    "No value found at "*) VERSION=0 ;;
    *) die "Vault failed the read of $DEST, so nothing was written." ;;
  esac
fi
echo "  version $VERSION"

step "Deploy key"
EXISTING_PUB=""
if [ "$VERSION" != 0 ]; then
  EXISTING_PUB="$(SNAP="$SNAP" python3 -c '
import json, os
print((json.loads(os.environ["SNAP"])["data"]["data"] or {}).get("deploy_ssh_public_key", ""))')"
fi
PRIV=""; PUB=""
if [ -n "$EXISTING_PUB" ] && [ "$ROTATE" = 0 ]; then
  echo "  kept: deploy_ssh_public_key is present"
else
  ssh-keygen -q -t ed25519 -N "" -C usaa-cd -f "$TMP/usaa-cd" || die "ssh-keygen failed."
  PRIV="$(cat "$TMP/usaa-cd")"; PUB="$(cat "$TMP/usaa-cd.pub")"
  rm -f "$TMP/usaa-cd" "$TMP/usaa-cd.pub"
  echo "  generated a new ed25519 pair"
fi

step "Write the fields"
# Both values travel as one JSON object on stdin (`-`), so neither reaches argv, where a
# process listing would show the notify token. The object holds only these two fields; a
# `patch` merges them into the others.
BODY="$(AUD="$AUD" NOTIFY="$NOTIFY" PRIV="$PRIV" PUB="$PUB" python3 -c '
import json, os
d = {"access_aud": os.environ["AUD"], "notify_bearer_token": os.environ["NOTIFY"]}
if os.environ["PUB"]:
    d["deploy_ssh_private_key"] = os.environ["PRIV"] + "\n"
    d["deploy_ssh_public_key"] = os.environ["PUB"]
print(json.dumps(d))')"
if [ "$VERSION" = 0 ]; then
  printf '%s' "$BODY" | vault kv put -cas=0 "$DEST" - >/dev/null \
    || die "vault kv put failed. If another writer created $DEST, run this again."
else
  printf '%s' "$BODY" | vault kv patch -cas="$VERSION" "$DEST" - >/dev/null \
    || die "vault kv patch failed. If another writer changed $DEST, run this again."
fi
unset BODY PRIV PUB

step "Verify, by reading it back"
[ "$(vault kv get -field=access_aud "$DEST")" = "$AUD" ] || die "access_aud does not match the write."
[ "$(vault kv get -field=notify_bearer_token "$DEST")" = "$NOTIFY" ] || die "notify_bearer_token does not match the write."
vault kv get -field=deploy_ssh_public_key "$DEST" | grep -q '^ssh-ed25519 ' || die "deploy_ssh_public_key is missing or malformed."
vault kv get -field=deploy_ssh_private_key "$DEST" | grep -q 'BEGIN OPENSSH PRIVATE KEY' || die "deploy_ssh_private_key is missing."
for f in batsy_bearer_token; do
  vault kv get -field="$f" "$DEST" >/dev/null 2>&1 || echo "  note: $f is absent in $DEST. Run seed-usaa-batsy-token.sh."
done
echo "  fields match the write; the key pair is present"
unset AUD NOTIFY SNAP

step "Done"
echo "  Next: ./scripts/deploy-usaa.sh from the Mac, then merge the petedio-usaa deploy workflow."
