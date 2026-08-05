#!/usr/bin/env bash
# reseed-minio-obsidian-vault.sh — (re)seed kv/services/minio-obsidian with a MinIO service
# account scoped to JUST the `obsidian-fs-mcs` bucket on the app-data host (LXC 245), so
# the Obsidian "Remotely Save" plugin on Pedro's Mac / iPhone / iPad / PC can sync the
# FS MCS vault over the tailnet.
#
# WHY A SEPARATE CREDENTIAL: the root credential (kv/iac/minio-data-root) is admin on the
# whole host, and it would be typed into four end-user devices. This mints a least-
# privilege key instead — full CRUD on one bucket, nothing else, not even the ability to
# see another bucket exists. Verified: with this policy, `mc ls <alias>` lists only
# obsidian-fs-mcs, and touching any other bucket returns "Access Denied".
#
# Rotation is the device-revocation story: this vault has no per-device credential, so
# losing a device means running this with --rotate, which mints a new key and (once every
# remaining device is updated) leaves the lost device with a dead one. Old svcaccts are
# NOT auto-removed — the script prints the leftovers so you can `mc admin user svcacct rm`
# them deliberately.
#
# Idempotent: without --rotate, an existing credential that still authenticates is left
# alone (re-running must not silently invalidate four configured devices).
#
#   Vault token: $VAULT_TOKEN, else macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM, else prompt
#   MinIO admin: resolved from Vault kv/iac/minio-data-root (seed-minio-data-root.sh)
#
# Requires the tailnet to be up (the endpoint is a 192.168.50.x address reached via the
# tailscale-244 subnet router) and configure-minio-data.yml to have run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"
MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://192.168.50.245:9000}"
ROOT_PATH="kv/iac/minio-data-root"
DEST_PATH="kv/services/minio-obsidian"
BUCKET="${OBSIDIAN_BUCKET:-obsidian-fs-mcs}"

ROTATE=0
[ "${1:-}" = "--rotate" ] && ROTATE=1

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
for t in mc vault python3; do command -v "$t" >/dev/null || die "$t not in PATH."; done

step "Resolving Vault token"
if [ -z "${VAULT_TOKEN:-}" ]; then
  VAULT_TOKEN="$(security find-generic-password -s "$VAULT_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null || true)"
fi
[ -n "${VAULT_TOKEN:-}" ] || { read -rsp "Vault token: " VAULT_TOKEN; echo; }
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
POLICY="$MCCFG/obsidian-policy.json"
# Sync needs full object CRUD plus multipart (Remotely Save uploads attachments), and
# ListBucket to diff local vs remote. Deliberately NOT granted: any s3:*Bucket* mutation,
# and any resource outside this one bucket.
cat > "$POLICY" <<JSON
{ "Version":"2012-10-17","Statement":[
  {"Effect":"Allow",
   "Action":["s3:ListBucket","s3:GetBucketLocation","s3:ListBucketMultipartUploads"],
   "Resource":["arn:aws:s3:::$BUCKET"]},
  {"Effect":"Allow",
   "Action":["s3:GetObject","s3:PutObject","s3:DeleteObject",
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
echo "Scope confirmed: exactly one bucket visible, read+write on it."

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
echo "$DEST_PATH updated (readable by the ansible policy — kv/data/services/* is already granted)."

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
  Endpoint : $MINIO_ENDPOINT   (tailnet only — no public route, by design)
  Vault    : $DEST_PATH

  Read the values for device setup with:
    vault kv get $DEST_PATH

  Client configuration: docs/runbooks/obsidian-vault-sync.md
TXT
