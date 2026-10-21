#!/usr/bin/env bash
# seed-pete-bot-cd-key.sh — give the pete-bot deploy its own SSH key, as
# deploy_ssh_private_key and deploy_ssh_public_key in kv/services/pete-bot (PET-724).
#
# WHY. The pete-bot-cd role reads the shared kv/iac/lxc-ssh key, which is root on every
# Terraform-built LXC. A deploy of one bot on 237 needs root on 237 only. This script makes
# an ed25519 pair for the app, scripts/deploy-pete-bot.sh authorizes the public half on
# media-dash-237, and the deploy workflow connects with the private half.
#
# HOW IT WRITES. `vault kv patch -cas=<version>` changes these two fields and keeps the
# others. The values go to Vault on stdin, never on the command line. The script prints
# field names and lengths, never a value, and reads the fields back. An existing pair is
# kept. To replace it, run with --rotate-key, then ./scripts/deploy-pete-bot.sh.
#
# THE ORDER, because the live deploy must never lose its way in:
#   1. this script, run by Pedro
#   2. ./scripts/deploy-pete-bot.sh from the Mac, which installs the public key on 237
#   3. merge the pete-bot deploy.yml change, which reads the new key
#   4. merge the PR that drops the lxc-ssh read from the pete-bot-cd policy, and apply
#
#   Vault token: $VAULT_TOKEN, else the macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM.
#
# Usage:
#   ./scripts/seed-pete-bot-cd-key.sh [--rotate-key]
set -euo pipefail
umask 077

case "${1:-}" in
  "") ROTATE=0 ;;
  --rotate-key) ROTATE=1 ;;
  -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
  *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
esac

HOST_NOTE="237 keeps authorizing the old public key until deploy-pete-bot.sh runs."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEST="kv/services/pete-bot"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"
export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$REPO_ROOT/environments/homelab/vault-ca.crt}"

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }
for t in vault python3 ssh-keygen; do command -v "$t" >/dev/null || die "$t not in PATH."; done

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

step "Read $DEST"
SNAP="$(vault kv get -format=json "$DEST" 2>/dev/null)" \
  || die "cannot read $DEST. Run scripts/seed-pete-bot-vault.sh first."
VERSION="$(SNAP="$SNAP" python3 -c 'import json,os; print(json.loads(os.environ["SNAP"])["data"]["metadata"]["version"])')" \
  || die "could not parse the read of $DEST."
EXISTING_PUB="$(SNAP="$SNAP" python3 -c '
import json, os
print((json.loads(os.environ["SNAP"])["data"]["data"] or {}).get("deploy_ssh_public_key", ""))')"
EXISTING_PRIV="$(SNAP="$SNAP" python3 -c '
import json, os
print("yes" if (json.loads(os.environ["SNAP"])["data"]["data"] or {}).get("deploy_ssh_private_key", "") else "")')"
unset SNAP
echo "  version $VERSION"

step "Deploy key"
if [ -n "$EXISTING_PUB" ] && [ -n "$EXISTING_PRIV" ] && [ "$ROTATE" = 0 ]; then
  # A kept pair must still be a pair: the stored private key has to derive the stored public key.
  vault kv get -field=deploy_ssh_public_key "$DEST" > "$TMP/kept.pub" || die "cannot read deploy_ssh_public_key."
  vault kv get -field=deploy_ssh_private_key "$DEST" > "$TMP/kept.key" || die "cannot read deploy_ssh_private_key."
  chmod 600 "$TMP/kept.key"
  [ "$(ssh-keygen -y -f "$TMP/kept.key" 2>/dev/null | awk '{print $2}')" = "$(awk '{print $2}' "$TMP/kept.pub")" ] \
    || die "the stored private key does not derive the stored public key. Run with --rotate-key."
  echo "  kept: the stored pair matches, fingerprint $(ssh-keygen -lf "$TMP/kept.pub" | awk '{print $2}'). Nothing to write."
  exit 0
fi
if [ -n "$EXISTING_PUB" ] && [ -z "$EXISTING_PRIV" ] && [ "$ROTATE" = 0 ]; then
  echo "  deploy_ssh_public_key is present but deploy_ssh_private_key is missing, so I replace the pair."
fi
if [ "$ROTATE" = 1 ]; then
  echo "  rotating. KV v2 keeps the old version. $HOST_NOTE"
fi
ssh-keygen -q -t ed25519 -N "" -C pete-bot-cd -f "$TMP/pete-bot-cd" || die "ssh-keygen failed."
echo "  generated a new ed25519 pair"

step "Write the fields"
# One JSON object on stdin (`-`), so the private key never reaches argv. A `patch` merges
# the two fields into the others, and -cas fails the write if another writer got there first.
PRIV="$(cat "$TMP/pete-bot-cd")" PUB="$(cat "$TMP/pete-bot-cd.pub")" python3 -c '
import json, os
print(json.dumps({"deploy_ssh_private_key": os.environ["PRIV"] + "\n",
                  "deploy_ssh_public_key": os.environ["PUB"]}))' \
  | vault kv patch -cas="$VERSION" "$DEST" - >/dev/null \
  || die "vault kv patch failed. If another writer changed $DEST, run this again."

step "Verify, by reading it back"
# The stored pair must be the pair generated above: the stored public key has the generated
# fingerprint, and the stored private key derives that same public key.
WANT_FP="$(ssh-keygen -lf "$TMP/pete-bot-cd.pub" | awk '{print $2}')"
vault kv get -field=deploy_ssh_public_key "$DEST" > "$TMP/back.pub" || die "cannot read deploy_ssh_public_key back."
GOT_FP="$(ssh-keygen -lf "$TMP/back.pub" 2>/dev/null | awk '{print $2}')"
[ -n "$GOT_FP" ] && [ "$GOT_FP" = "$WANT_FP" ] || die "the stored public key does not match the generated one."
vault kv get -field=deploy_ssh_private_key "$DEST" > "$TMP/back.key" || die "cannot read deploy_ssh_private_key back."
chmod 600 "$TMP/back.key"
[ "$(ssh-keygen -y -f "$TMP/back.key" 2>/dev/null | awk '{print $2}')" = "$(awk '{print $2}' "$TMP/back.pub")" ] \
  || die "the stored private key does not derive the stored public key."
echo "  fingerprint $GOT_FP"
for f in discord_token notify_bearer_token; do
  vault kv get -field="$f" "$DEST" >/dev/null 2>&1 || die "$f vanished from $DEST. Restore the previous version with vault kv rollback."
done
echo "  the key pair is present, and the other fields are intact"

step "Done"
echo "  Next: ./scripts/deploy-pete-bot.sh from the Mac. Do not merge the deploy.yml change before it."
