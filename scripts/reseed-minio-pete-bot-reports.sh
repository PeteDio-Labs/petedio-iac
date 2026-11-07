#!/usr/bin/env bash
# reseed-minio-pete-bot-reports.sh — (re)seed kv/services/pete-bot-reports-backup with a MinIO
# service account scoped to JUST the `pete-bot` bucket on the app-data host (LXC 245), so pete-bot
# on 237 can copy its reports database there each day (PET-868). pete-bot's deploy.yml reads the
# path and passes the key to configure-pete-bot.yml, which renders REPORT_BACKUP_* into the bot's
# environment file.
#
# WHY A SEPARATE CREDENTIAL: the root credential (kv/iac/minio-data-root) is admin on the whole
# host. This mints a least-privilege key: read, write and list in one bucket, and no delete.
# The bucket keeps object versions, so a key that cannot delete cannot erase the history either.
#
# Idempotent: an existing credential that still authenticates is left alone. Rotate with --rotate.
# Old service accounts are not removed; the script lists them so you remove them on purpose.
#
#   Vault token: $VAULT_TOKEN, else macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM. No prompt (PET-519)
#   MinIO admin: resolved from Vault kv/iac/minio-data-root (seed-minio-data-root.sh)
#
# Needs the tailnet (the endpoint is a 192.168.50.x address) and the `pete-bot` bucket, which
# configure-minio-data.yml creates from inventory/group_vars/minio_data.yml
# (scripts/deploy-minio-data.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"
MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://192.168.50.245:9000}"
ROOT_PATH="kv/iac/minio-data-root"
DEST_PATH="kv/services/pete-bot-reports-backup"
BUCKET="${PETE_BOT_BACKUP_BUCKET:-pete-bot}"

ROTATE=0
[ "${1:-}" = "--rotate" ] && ROTATE=1

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
for t in mc vault python3; do command -v "$t" >/dev/null || die "$t not in PATH."; done

step "Resolving Vault token"
if [ -z "${VAULT_TOKEN:-}" ]; then
  VAULT_TOKEN="$(security find-generic-password -s "$VAULT_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null || true)"
fi
[ -n "${VAULT_TOKEN:-}" ] || die "no Vault token: set VAULT_TOKEN or add the Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM"
export VAULT_TOKEN
vault token lookup >/dev/null 2>&1 || die "Vault token invalid / Vault unreachable."

step "Resolving the .245 MinIO admin creds from $ROOT_PATH (used locally only — never re-written)"
MROOT_U="$(vault kv get -field=root_user "$ROOT_PATH" 2>/dev/null || true)"
MROOT_P="$(vault kv get -field=root_password "$ROOT_PATH" 2>/dev/null || true)"
[ -n "$MROOT_U" ] && [ -n "$MROOT_P" ] \
  || die "$ROOT_PATH not seeded. Run ./scripts/seed-minio-data-root.sh first."

step "Authenticating to MinIO at $MINIO_ENDPOINT"
MCCFG="$(mktemp -d)"; trap 'rm -rf "$MCCFG"' EXIT
mc --config-dir "$MCCFG" alias set adm "$MINIO_ENDPOINT" "$MROOT_U" "$MROOT_P" >/dev/null 2>&1 \
  || die "MinIO admin creds rejected by $MINIO_ENDPOINT (is the tailnet up? has configure-minio-data.yml run?)."

# The bucket is the ROLE's job (inventory/group_vars/minio_data.yml), not this script's —
# creating it here would let a bucket exist with no versioning and no quota. Fail instead.
mc --config-dir "$MCCFG" ls "adm/$BUCKET" >/dev/null 2>&1 \
  || die "bucket '$BUCKET' does not exist on $MINIO_ENDPOINT — run configure-minio-data.yml first (it also sets versioning + the quota)."

step "Checking whether $DEST_PATH already holds a working credential"
if [ "$ROTATE" -eq 0 ]; then
  OLD_AK="$(vault kv get -field=access_key "$DEST_PATH" 2>/dev/null || true)"
  OLD_SK="$(vault kv get -field=secret_key "$DEST_PATH" 2>/dev/null || true)"
  if [ -n "$OLD_AK" ] && [ -n "$OLD_SK" ] \
     && mc --config-dir "$MCCFG" alias set old "$MINIO_ENDPOINT" "$OLD_AK" "$OLD_SK" >/dev/null 2>&1 \
     && mc --config-dir "$MCCFG" ls "old/$BUCKET" >/dev/null 2>&1; then
    unset OLD_SK
    echo "Existing credential still authenticates and can reach $BUCKET — leaving it alone."
    echo "Re-run with --rotate to mint a new one (then update every device)."
    exit 0
  fi
  unset OLD_SK
  echo "No usable existing credential — minting one."
fi

step "Minting a service account scoped to JUST the $BUCKET bucket"
POLICY="$MCCFG/pete-bot-policy.json"
# The copy needs to write an object (multipart for a larger file) and to read it back for a
# restore. Deliberately NOT granted: s3:DeleteObject, any s3:*Bucket* mutation, and any resource
# outside this one bucket.
cat > "$POLICY" <<JSON
{ "Version":"2012-10-17","Statement":[
  {"Effect":"Allow",
   "Action":["s3:ListBucket","s3:GetBucketLocation","s3:ListBucketMultipartUploads"],
   "Resource":["arn:aws:s3:::$BUCKET"]},
  {"Effect":"Allow",
   "Action":["s3:GetObject","s3:PutObject",
             "s3:AbortMultipartUpload","s3:ListMultipartUploadParts"],
   "Resource":["arn:aws:s3:::$BUCKET/*"]}
]}
JSON
SVC_JSON="$(mc --config-dir "$MCCFG" admin user svcacct add --policy "$POLICY" --json adm "$MROOT_U")"
NEW_AK="$(printf '%s' "$SVC_JSON" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("accessKey") or "")')"
NEW_SK="$(printf '%s' "$SVC_JSON" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("secretKey") or "")')"
unset SVC_JSON
[ -n "$NEW_AK" ] && [ -n "$NEW_SK" ] || die "failed to mint/parse the service account."
echo "Minted svcacct scoped to $BUCKET (access key len ${#NEW_AK})."

step "Verifying the new svcacct: can use $BUCKET, cannot see anything else"
mc --config-dir "$MCCFG" alias set chk "$MINIO_ENDPOINT" "$NEW_AK" "$NEW_SK" >/dev/null 2>&1 \
  || die "freshly-minted svcacct did not authenticate."
mc --config-dir "$MCCFG" ls "chk/$BUCKET/" >/dev/null 2>&1 \
  || die "freshly-minted svcacct cannot list $BUCKET — check the policy."
VISIBLE="$(mc --config-dir "$MCCFG" ls chk 2>/dev/null | grep -c . || true)"
[ "$VISIBLE" -le 1 ] \
  || die "svcacct can see $VISIBLE buckets, expected 1 — the policy is wider than intended."
echo "Scope confirmed: exactly one bucket visible."
# The key must write and must not delete. Test both with a throwaway object.
PROBE="$MCCFG/probe.txt"; echo probe > "$PROBE"
mc --config-dir "$MCCFG" cp "$PROBE" "chk/$BUCKET/.write-probe" >/dev/null 2>&1 \
  || die "the new key cannot write to $BUCKET."
if mc --config-dir "$MCCFG" rm "chk/$BUCKET/.write-probe" >/dev/null 2>&1; then
  die "the new key can delete from $BUCKET, so the policy is wider than intended."
fi
mc --config-dir "$MCCFG" rm "adm/$BUCKET/.write-probe" >/dev/null 2>&1 || true
echo "Write works; delete is refused."

step "Writing $DEST_PATH"
# JSON on stdin so the keys never appear in argv. `put` is right for this dedicated path
# (nothing else lives on it); endpoint/bucket are stored alongside so the runbook and any
# future consumer read one place instead of hardcoding .245.
MO_AK="$NEW_AK" MO_SK="$NEW_SK" MO_EP="$MINIO_ENDPOINT" MO_BK="$BUCKET" python3 -c '
import json, os
print(json.dumps({"access_key": os.environ["MO_AK"], "secret_key": os.environ["MO_SK"],
                  "endpoint": os.environ["MO_EP"], "bucket": os.environ["MO_BK"]}))
' | vault kv put "$DEST_PATH" - >/dev/null
unset NEW_SK
echo "$DEST_PATH updated (pete-bot-cd reads it, from vault-config/policies.tf)."

step "Leftover service accounts on this host (rotation hygiene)"
# Every rotation leaves the previous svcacct valid until removed. Listing them here makes
# that visible instead of accumulating silently; remove old ones once every device is
# re-configured:  mc admin user svcacct rm adm <accessKey>
mc --config-dir "$MCCFG" admin user svcacct ls --json adm "$MROOT_U" 2>/dev/null \
  | python3 -c '
import sys, json
cur = sys.argv[1]
rows = [json.loads(l) for l in sys.stdin if l.strip()]
keys = [r.get("accessKey") for r in rows if r.get("accessKey")]
others = [k for k in keys if k != cur]
print(f"  in use now: {cur}")
print("  older svcaccts still valid: " + (", ".join(others) if others else "none"))
' "$NEW_AK" || echo "  (could not enumerate — check by hand with: mc admin user svcacct ls adm $MROOT_U)"

step "Done"
cat <<TXT
  Bucket   : $BUCKET
  Endpoint : $MINIO_ENDPOINT
  Vault    : $DEST_PATH

  The key reaches pete-bot on the next deploy: push to pete-bot main, or run its deploy workflow.
  Then read weekly.backup in the bot's /health on 237 for state "ok".
TXT
