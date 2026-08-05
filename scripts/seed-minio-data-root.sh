#!/usr/bin/env bash
# seed-minio-data-root.sh — seed (or rotate) the MinIO ROOT credentials for the app-data
# host, LXC 245, at Vault kv/iac/minio-data-root.
#
# WHY A SEPARATE PATH FROM .221. kv/iac/minio-root is the state backend's root credential.
# Sharing it would mean one admin secret unlocking both the host holding Terraform's state
# and the host holding app data — the exact blast radius LXC 245 exists to avoid. Two
# hosts, two root credentials, no overlap.
#
# ORDER: this runs BEFORE the first configure-minio-data.yml, because the role writes these
# values into /etc/default/minio as MINIO_ROOT_USER/PASSWORD — they define the admin
# account rather than discovering it. Rotating them here and re-running the play rotates
# the live root credential; any svcacct minted under it survives (svcaccts have their own
# keys), but re-run reseed-minio-obsidian-vault.sh if you want a fresh scoped key too.
#
# IDEMPOTENT: if kv/iac/minio-data-root already holds a credential this exits without
# touching it. Pass --rotate to generate and store a new password.
#
#   Vault token: $VAULT_TOKEN, else macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM, else prompt
#
# No secret is ever printed, passed in argv, or written to disk unencrypted.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"
VAULT_PATH="kv/iac/minio-data-root"
ROOT_USER="${MINIO_DATA_ROOT_USER:-minio-data-admin}"

ROTATE=0
[ "${1:-}" = "--rotate" ] && ROTATE=1

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
for t in vault python3; do command -v "$t" >/dev/null || die "$t not in PATH."; done

step "Resolving Vault token"
if [ -z "${VAULT_TOKEN:-}" ]; then
  VAULT_TOKEN="$(security find-generic-password -s "$VAULT_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null || true)"
fi
[ -n "${VAULT_TOKEN:-}" ] || { read -rsp "Vault token: " VAULT_TOKEN; echo; }
export VAULT_TOKEN
vault token lookup >/dev/null 2>&1 || die "Vault token invalid / Vault unreachable."

step "Checking $VAULT_PATH"
EXISTING="$(vault kv get -field=root_password "$VAULT_PATH" 2>/dev/null || true)"
if [ -n "$EXISTING" ] && [ "$ROTATE" -eq 0 ]; then
  unset EXISTING
  echo "Already seeded — leaving it alone. Re-run with --rotate to replace it."
  echo "(A rotate is only live once configure-minio-data.yml re-runs and restarts MinIO.)"
  exit 0
fi
unset EXISTING

step "Generating a root password"
# 32 URL-safe chars from the OS CSPRNG. No shell-special characters: this value lands in a
# systemd EnvironmentFile and in `mc alias set`, and a stray quote/backslash there fails in
# ways that look like "wrong credentials" (cf. the resume-builder Mongo password gotcha,
# vault/Systems/resume-builder.md).
NEW_PW="$(python3 -c 'import secrets,string; a=string.ascii_letters+string.digits; print("".join(secrets.choice(a) for _ in range(32)))')"
[ ${#NEW_PW} -eq 32 ] || die "password generation failed."

step "Writing $VAULT_PATH"
# JSON on stdin, so neither value appears in argv (visible in ps) — the documented Vault
# write convention. `put` (not `patch`) is correct here: this path is dedicated to these
# two fields, so there is nothing else on it to clobber.
MINIO_ROOT_USER_V="$ROOT_USER" MINIO_ROOT_PASSWORD_V="$NEW_PW" python3 -c '
import json, os
print(json.dumps({"root_user": os.environ["MINIO_ROOT_USER_V"],
                  "root_password": os.environ["MINIO_ROOT_PASSWORD_V"]}))
' | vault kv put "$VAULT_PATH" - >/dev/null
unset NEW_PW

step "Verifying (without printing the secret)"
vault kv get -field=root_user "$VAULT_PATH" >/dev/null || die "read-back of root_user failed."
LEN="$(vault kv get -field=root_password "$VAULT_PATH" | wc -c | tr -d ' ')"
[ "$LEN" -ge 32 ] || die "read-back of root_password looks wrong (len $LEN)."
echo "$VAULT_PATH seeded (root_user=$ROOT_USER, password length ok)."

step "Next"
cat <<'TXT'
  1. ./scripts/deploy-minio-data.sh            # installs MinIO on 245 with these creds
  2. ./scripts/reseed-minio-obsidian-vault.sh  # mints the bucket-scoped sync credential
TXT
