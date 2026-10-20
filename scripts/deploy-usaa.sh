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
# The month view (PET-590, 2026-10-20) adds three optional values. A missing one prints a
# warning and leaves that part of the app off, so a deploy before its seed still works:
#   kv/services/usaa      field bobberto_bearer_token   seed-usaa-batsy-token.sh --agent bobberto
#   kv/services/usaa      field calendar_ics_url        seed-usaa-calendar-url.sh
#   kv/services/pete-bot  field notify_bearer_token     already seeded for pete-bot (PET-584)
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
# Optional: pete-bot's notify token, for the month view's Discord alerts. An unreadable
# path is a warning, not a stop, because the app runs without alerts.
vault kv get -format=json kv/services/pete-bot >"$TMP/pb.json" 2>/dev/null || echo '{"data":{"data":{}}}' >"$TMP/pb.json"
python3 -c '
import json, os, sys, yaml
db = json.load(open(sys.argv[2]))["data"]["data"]
svc = json.load(open(sys.argv[3]))["data"]["data"]
pb = json.load(open(sys.argv[4]))["data"]["data"] or {}
if not db.get("password"):
    sys.exit("kv/db/usaa has no password field: run the PET-590 kv/db/usaa seed (M1).")
if not svc.get("batsy_bearer_token"):
    sys.exit("kv/services/usaa has no batsy_bearer_token field: run the PET-590 kv/services/usaa seed (M1).")
optional = {
    "usaa_bobberto_bearer": (svc, "bobberto_bearer_token", "Bobberto cannot push or read: run seed-usaa-batsy-token.sh --agent bobberto"),
    "usaa_calendar_ics_url": (svc, "calendar_ics_url", "the month view has no calendar: run seed-usaa-calendar-url.sh"),
    "usaa_notify_bearer": (pb, "notify_bearer_token", "alerts stay on /month and reach no DM"),
}
out = {
    "usaa_db_password": db["password"],
    "usaa_batsy_bearer": svc["batsy_bearer_token"],
    "usaa_access_aud": os.environ["USAA_ACCESS_AUD"],
}
for var, (src, field, why) in optional.items():
    out[var] = src.get(field) or ""
    # Say which field is missing, never what a present one holds.
    # No single quote anywhere in this program: the shell passes it single-quoted.
    print("  " + field + ": " + ("present" if out[var] else "MISSING, " + why), file=sys.stderr)
yaml.safe_dump(out, open(sys.argv[1], "w"))
' "$TMP/extra.yml" "$TMP/db.json" "$TMP/svc.json" "$TMP/pb.json"
rm -f "$TMP/db.json" "$TMP/svc.json" "$TMP/pb.json"

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
