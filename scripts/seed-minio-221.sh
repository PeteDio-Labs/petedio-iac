#!/usr/bin/env bash
# seed-minio-221.sh — seed the two Vault paths the PET-741 register check found absent:
#   kv/iac/minio-root            the .221 MinIO root credential (root_user, root_password)
#   kv/services/vault-snapshots  a svcacct scoped to the vault-snapshots bucket (access_key, secret_key)
#
# kv/iac/minio-root is the rebuild input for configure-minio.yml. Terraform's state backend
# does not use it: that is a tfstate-scoped svcacct at kv/iac/minio (reseed-minio-vault.sh).
# The vault-snapshot role reads kv/services/vault-snapshots (PET-109). The runbook minted
# it by hand; this script replaces that step.
#
# IDEMPOTENT. A path that already holds a working credential is left alone. Pass --refresh
# to mint a new vault-snapshots svcacct and to overwrite kv/iac/minio-root.
#
#   Vault token: $VAULT_TOKEN, else macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM. No prompt (PET-519)
#   MinIO root:  $MINIO_ROOT_USER/$MINIO_ROOT_PASSWORD, else $MINIO_CREDS_FILE
#                (default ~/petedio/.secrets/minio-221.txt, lines ROOT_USER=… and ROOT_PASSWORD=…).
#                This script never prompts for it and never prints it.
#
# Usage:
#   ./scripts/seed-minio-221.sh            # seed what is absent
#   ./scripts/seed-minio-221.sh --refresh  # replace both
set -euo pipefail
umask 077

REFRESH=0
for arg in "$@"; do
  case "$arg" in
    --refresh) REFRESH=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"
MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://192.168.50.221:9000}"
MINIO_CREDS_FILE="${MINIO_CREDS_FILE:-$HOME/petedio/.secrets/minio-221.txt}"
ROOT_PATH="kv/iac/minio-root"
SNAP_PATH="kv/services/vault-snapshots"
BUCKET="vault-snapshots"

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }
for t in vault mc python3; do command -v "$t" >/dev/null || die "$t not in PATH."; done

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

step "MinIO root credential for $MINIO_ENDPOINT (used locally)"
MROOT_U="${MINIO_ROOT_USER:-}"; MROOT_P="${MINIO_ROOT_PASSWORD:-}"
if { [ -z "$MROOT_U" ] || [ -z "$MROOT_P" ]; } && [ -f "$MINIO_CREDS_FILE" ]; then
  MROOT_U="$(grep -iE 'ROOT_USER'     "$MINIO_CREDS_FILE" | head -1 | sed 's/.*[=:][[:space:]]*//' | tr -d ' "'\''')"
  MROOT_P="$(grep -iE 'ROOT_PASSWORD' "$MINIO_CREDS_FILE" | head -1 | sed 's/.*[=:][[:space:]]*//' | tr -d ' "'\''')"
fi
[ -n "$MROOT_U" ] && [ -n "$MROOT_P" ] \
  || die "no MinIO root credential. Export MINIO_ROOT_USER and MINIO_ROOT_PASSWORD, or write them to $MINIO_CREDS_FILE."
MCCFG="$(mktemp -d)"; trap 'rm -rf "$MCCFG"' EXIT
# MC_HOST_<alias> carries the credential in the environment, so it never reaches argv.
export MC_HOST_adm="${MINIO_ENDPOINT%%://*}://${MROOT_U}:${MROOT_P}@${MINIO_ENDPOINT#*://}"
mc --config-dir "$MCCFG" ls adm >/dev/null 2>&1 \
  || die "$MINIO_ENDPOINT rejected the root credential, or it is unreachable (is the tailnet up?)."
echo "  the root credential authenticates (user length ${#MROOT_U})"

# vget PATH FIELD prints the field, or nothing when the path or field is absent.
vget(){
  local out
  if out="$(vault kv get -field="$2" "$1" 2>&1)"; then printf '%s' "$out"; return 0; fi
  case "$out" in
    "No value found at "*|*"no field named"*|*"Field \""*"not present"*) return 0 ;;
    *) die "Vault failed the read of $1: $(printf '%s' "$out" | tr -s '\n\t' '  ' | cut -c1-200)" ;;
  esac
}

step "$ROOT_PATH"
CUR_U="$(vget "$ROOT_PATH" root_user)"; CUR_P="$(vget "$ROOT_PATH" root_password)"
if [ "$REFRESH" = "0" ] && [ -n "$CUR_U" ] && [ -n "$CUR_P" ]; then
  echo "  already holds a root credential. Leaving it alone."
else
  # JSON on stdin, so neither value reaches argv.
  MU="$MROOT_U" MP="$MROOT_P" python3 -c '
import json, os
print(json.dumps({"root_user": os.environ["MU"], "root_password": os.environ["MP"]}))' \
    | vault kv put "$ROOT_PATH" - >/dev/null || die "vault kv put failed for $ROOT_PATH."
  [ "$(vget "$ROOT_PATH" root_user)" = "$MROOT_U" ] && [ "$(vget "$ROOT_PATH" root_password)" = "$MROOT_P" ] \
    || die "the read-back of $ROOT_PATH does not match."
  echo "  written, and the read-back matches"
fi
unset CUR_U CUR_P

step "Bucket $BUCKET"
if mc --config-dir "$MCCFG" ls "adm/$BUCKET" >/dev/null 2>&1; then
  echo "  exists"
else
  mc --config-dir "$MCCFG" mb "adm/$BUCKET" >/dev/null || die "could not create the bucket $BUCKET."
  mc --config-dir "$MCCFG" version enable "adm/$BUCKET" >/dev/null || die "could not enable versioning on $BUCKET."
  echo "  created, with versioning"
fi

step "$SNAP_PATH"
OLD_AK="$(vget "$SNAP_PATH" access_key)"; OLD_SK="$(vget "$SNAP_PATH" secret_key)"
if [ "$REFRESH" = "0" ] && [ -n "$OLD_AK" ] && [ -n "$OLD_SK" ] \
   && MC_HOST_old="${MINIO_ENDPOINT%%://*}://${OLD_AK}:${OLD_SK}@${MINIO_ENDPOINT#*://}" \
        mc --config-dir "$MCCFG" ls "old/$BUCKET" >/dev/null 2>&1; then
  unset OLD_SK
  echo "  holds a credential that still reaches $BUCKET. Leaving it alone."
else
  unset OLD_SK
  # The snapshot script uploads objects and the restore runbook lists and reads them.
  # It gets no delete and no access to any other bucket.
  POLICY="$MCCFG/vault-snapshots-policy.json"
  cat > "$POLICY" <<JSON
{ "Version":"2012-10-17","Statement":[
  {"Effect":"Allow","Action":["s3:ListBucket","s3:GetBucketLocation"],"Resource":["arn:aws:s3:::$BUCKET"]},
  {"Effect":"Allow","Action":["s3:GetObject","s3:PutObject","s3:AbortMultipartUpload","s3:ListMultipartUploadParts"],
   "Resource":["arn:aws:s3:::$BUCKET/*"]}
]}
JSON
  SVC_JSON="$(mc --config-dir "$MCCFG" admin user svcacct add --policy "$POLICY" --json adm "$MROOT_U")"
  NEW_AK="$(printf '%s' "$SVC_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("accessKey") or "")')"
  NEW_SK="$(printf '%s' "$SVC_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("secretKey") or "")')"
  unset SVC_JSON
  [ -n "$NEW_AK" ] && [ -n "$NEW_SK" ] || die "could not mint or parse the service account."
  export MC_HOST_chk="${MINIO_ENDPOINT%%://*}://${NEW_AK}:${NEW_SK}@${MINIO_ENDPOINT#*://}"
  mc --config-dir "$MCCFG" ls chk >/dev/null 2>&1 \
    || die "the new service account did not authenticate."
  mc --config-dir "$MCCFG" ls "chk/$BUCKET/" >/dev/null 2>&1 \
    || die "the new service account cannot list $BUCKET."
  [ "$(mc --config-dir "$MCCFG" ls chk 2>/dev/null | grep -c .)" -le 1 ] \
    || die "the new service account sees more than one bucket. The policy is wider than intended."
  NK="$NEW_AK" NS="$NEW_SK" python3 -c '
import json, os
print(json.dumps({"access_key": os.environ["NK"], "secret_key": os.environ["NS"]}))' \
    | vault kv put "$SNAP_PATH" - >/dev/null || die "vault kv put failed for $SNAP_PATH."
  [ "$(vget "$SNAP_PATH" access_key)" = "$NEW_AK" ] && [ "$(vget "$SNAP_PATH" secret_key)" = "$NEW_SK" ] \
    || die "the read-back of $SNAP_PATH does not match."
  echo "  minted a service account scoped to $BUCKET (access key length ${#NEW_AK}) and wrote it"
  unset NEW_SK
fi
unset MROOT_P

step "Done"
cat <<'NOTE'
  Next: run the secrets-register workflow once with workflow_dispatch. To prove the snapshot
  path end to end, run `systemctl start vault-snapshot.service` on 223 and `mc ls` the bucket.
NOTE
