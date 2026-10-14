#!/usr/bin/env bash
# deploy-usaa.sh — build petedio-usaa and deploy it to usaa-238 (PET-590).
#
# It compiles the binary here, for Linux x86-64, and the playbook copies it. Nothing
# builds on the target.
#
# Secrets come from Vault and reach ansible-playbook as an extra-vars FILE, never on argv
# and never printed:
#   kv/db/usaa        field password             the `usaa` database role's password
#   kv/services/usaa  field batsy_bearer_token   the bearer Batsy presents on the feed
# Both are seeded by the PET-590 vault-seeds change. This script reads them and mints
# nothing.
#
# It also reads the usaa_access_aud Terraform output (the Access application audience tag
# for savings.pdlab.dev, which the app checks on the Cf-Access-Jwt-Assertion JWT). That is an
# identifier, not a secret, and it goes in the same extra-vars file to keep argv clean. The
# state backend is MinIO, so the script reads kv/iac/minio as apply-vault-config.sh does.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"
SRC="${USAA_SRC:-$HOME/petedio/usaa}"
DB_PATH="kv/db/usaa"
SERVICE_PATH="kv/services/usaa"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
for t in vault terraform ansible-playbook bun python3; do command -v "$t" >/dev/null || die "$t not in PATH."; done
[ -d "$SRC" ] || die "No petedio-usaa checkout at $SRC (set USAA_SRC)."
# petedio-usaa's bun.lock is lockfileVersion 2, written by Bun 1.4.2. Bun 1.3.14 prints
# "Ignoring lockfile" and fails --frozen-lockfile, so check the version up front.
BUN_MIN=1.4.2
BUN_VER="$(bun --version)"
[ "$(printf '%s\n%s\n' "$BUN_MIN" "$BUN_VER" | sort -V | head -1)" = "$BUN_MIN" ] \
  || die "bun $BUN_VER is older than $BUN_MIN, which petedio-usaa's bun.lock needs. Run: bun upgrade"

step "Resolving Vault token"
if [ -z "${VAULT_TOKEN:-}" ]; then
  VAULT_TOKEN="$(security find-generic-password -s "$VAULT_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null || true)"
fi
[ -n "${VAULT_TOKEN:-}" ] || die "no Vault token: set VAULT_TOKEN or add the Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM"
export VAULT_TOKEN
vault token lookup >/dev/null 2>&1 || die "Vault token invalid / Vault unreachable."

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
umask 077

step "Reading the Access audience from Terraform state"
# The homelab state lives in the MinIO S3 backend.
AWS_ACCESS_KEY_ID="$(vault kv get -field=access_key kv/iac/minio)"; export AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY="$(vault kv get -field=secret_key kv/iac/minio)"; export AWS_SECRET_ACCESS_KEY
[ -n "$AWS_ACCESS_KEY_ID" ] || die "could not read kv/iac/minio access_key."
[ -n "$AWS_SECRET_ACCESS_KEY" ] || die "could not read kv/iac/minio secret_key."
terraform -chdir="$HOMELAB" init -reconfigure -input=false >"$TMP/init.log" 2>&1 \
  || { tail -15 "$TMP/init.log"; die "terraform init failed."; }
USAA_ACCESS_AUD="$(terraform -chdir="$HOMELAB" output -raw usaa_access_aud 2>/dev/null || true)"
[ -n "$USAA_ACCESS_AUD" ] || die "terraform output usaa_access_aud is empty or missing: apply petedio-iac#424 first."
export USAA_ACCESS_AUD
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY # the state read is done; ansible does not need them

step "Reading $DB_PATH and $SERVICE_PATH"
vault kv get -format=json "$DB_PATH" >"$TMP/db.json" \
  || die "cannot read $DB_PATH: run the PET-590 kv/db/usaa seed, and check that the ci-read grant is applied."
vault kv get -format=json "$SERVICE_PATH" >"$TMP/svc.json" \
  || die "cannot read $SERVICE_PATH: run the PET-590 kv/services/usaa seed."
python3 -c '
import json, os, sys, yaml
db = json.load(open(sys.argv[2]))["data"]["data"]
svc = json.load(open(sys.argv[3]))["data"]["data"]
if not db.get("password"):
    sys.exit("kv/db/usaa has no password field: run the PET-590 kv/db/usaa seed (M1).")
if not svc.get("batsy_bearer_token"):
    sys.exit("kv/services/usaa has no batsy_bearer_token field: run the PET-590 kv/services/usaa seed (M1).")
yaml.safe_dump({
    "usaa_db_password": db["password"],
    "usaa_batsy_bearer": svc["batsy_bearer_token"],
    "usaa_access_aud": os.environ["USAA_ACCESS_AUD"],
}, open(sys.argv[1], "w"))
' "$TMP/extra.yml" "$TMP/db.json" "$TMP/svc.json"
rm -f "$TMP/db.json" "$TMP/svc.json"

step "Compiling the binary"
# ⚠ NAME THE TARGET. `bun build --compile` builds for the machine it runs on, and a Mac
# build is Mach-O arm64 (PET-521). The argument is appended to the package's build script.
( cd "$SRC" && bun install --frozen-lockfile >/dev/null && bun run build --target=bun-linux-x64 )
[ -x "$SRC/dist/petedio-usaa" ] || die "bun run build produced no dist/petedio-usaa."
file -b "$SRC/dist/petedio-usaa" | grep -q '^ELF 64-bit.*x86-64' \
  || die "dist/petedio-usaa is not a Linux x86-64 binary: $(file -b "$SRC/dist/petedio-usaa")"
ls -lh "$SRC/dist/petedio-usaa"

step "Running configure-usaa.yml"
cd "$REPO_ROOT/ansible"
ansible-playbook playbooks/configure-usaa.yml \
  -e usaa_binary_src="$SRC/dist/petedio-usaa" \
  -e "@$TMP/extra.yml" \
  "$@"
