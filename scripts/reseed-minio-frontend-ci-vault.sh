#!/usr/bin/env bash
# reseed-minio-frontend-ci-vault.sh — (re)seed kv/services/minio-frontend-ci with a
# MinIO service account scoped to the `co-latro-frontend` bucket with READ+WRITE, so
# the frontend CI (publish-on-merge) can `mc mirror` dist/ INTO the bucket. (PET-79)
#
# WHY A SEPARATE CREDENTIAL FROM minio-frontend: that one is READ-ONLY (the on-box
# rollout pulls FROM the bucket). Publish needs WRITE (Put/Delete). Least-privilege =
# two creds, read for the box, write for CI. Read by the colatro-ci policy.
#
# Idempotent. No secrets printed. Reads creds locally at runtime.
#   Vault token: $VAULT_TOKEN, else macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM, else prompt
#   MinIO admin: $MINIO_ROOT_USER/$MINIO_ROOT_PASSWORD, else $MINIO_CREDS_FILE, else prompt
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"
MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://192.168.50.221:9000}"
MINIO_CREDS_FILE="${MINIO_CREDS_FILE:-$HOME/petedio/.secrets/minio-221.txt}"
BUCKET="${FRONTEND_BUCKET:-co-latro-frontend}"

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

step "Resolving MinIO admin creds (used locally only — never written to Vault)"
MROOT_U="${MINIO_ROOT_USER:-}"; MROOT_P="${MINIO_ROOT_PASSWORD:-}"
if { [ -z "$MROOT_U" ] || [ -z "$MROOT_P" ]; } && [ -f "$MINIO_CREDS_FILE" ]; then
  MROOT_U="$(grep -iE 'ROOT_USER'     "$MINIO_CREDS_FILE" | head -1 | sed 's/.*[=:][[:space:]]*//' | tr -d ' "'\''')"
  MROOT_P="$(grep -iE 'ROOT_PASSWORD' "$MINIO_CREDS_FILE" | head -1 | sed 's/.*[=:][[:space:]]*//' | tr -d ' "'\''')"
fi
[ -n "$MROOT_U" ] || read -rp  "MinIO admin user: " MROOT_U
[ -n "$MROOT_P" ] || { read -rsp "MinIO admin password: " MROOT_P; echo; }

step "Authenticating to MinIO + ensuring the $BUCKET bucket exists"
MCCFG="$(mktemp -d)"; trap 'rm -rf "$MCCFG"' EXIT
mc --config-dir "$MCCFG" alias set adm "$MINIO_ENDPOINT" "$MROOT_U" "$MROOT_P" >/dev/null 2>&1 \
  || die "MinIO admin creds rejected by $MINIO_ENDPOINT."
mc --config-dir "$MCCFG" mb --ignore-existing "adm/$BUCKET" >/dev/null 2>&1 || true

step "Minting a READ+WRITE service account scoped to JUST the $BUCKET bucket"
POLICY="$MCCFG/frontend-ci-policy.json"
cat > "$POLICY" <<JSON
{ "Version":"2012-10-17","Statement":[
  {"Effect":"Allow","Action":["s3:ListBucket","s3:GetBucketLocation"],"Resource":["arn:aws:s3:::$BUCKET"]},
  {"Effect":"Allow","Action":["s3:GetObject","s3:PutObject","s3:DeleteObject"],"Resource":["arn:aws:s3:::$BUCKET/*"]}
]}
JSON
SVC_JSON="$(mc --config-dir "$MCCFG" admin user svcacct add --policy "$POLICY" --json adm "$MROOT_U")"
NEW_AK="$(printf '%s' "$SVC_JSON" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("accessKey") or "")')"
NEW_SK="$(printf '%s' "$SVC_JSON" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("secretKey") or "")')"
[ -n "$NEW_AK" ] && [ -n "$NEW_SK" ] || die "failed to mint/parse the service account."
echo "Minted read+write svcacct for $BUCKET (access key len ${#NEW_AK})."

step "Verifying the new svcacct can write+delete in $BUCKET"
mc --config-dir "$MCCFG" alias set chk "$MINIO_ENDPOINT" "$NEW_AK" "$NEW_SK" >/dev/null 2>&1 \
  || die "freshly-minted svcacct did not authenticate."
PROBE="$MCCFG/.ci-write-probe"; echo ok > "$PROBE"
mc --config-dir "$MCCFG" cp "$PROBE" "chk/$BUCKET/.ci-write-probe" >/dev/null 2>&1 \
  && mc --config-dir "$MCCFG" rm "chk/$BUCKET/.ci-write-probe" >/dev/null 2>&1 \
  && echo "   write+delete OK" || die "svcacct cannot write to $BUCKET."

step "Writing the new creds to Vault kv/services/minio-frontend-ci"
vault kv put kv/services/minio-frontend-ci \
  access_key="$NEW_AK" secret_key="$NEW_SK" endpoint="$MINIO_ENDPOINT" bucket="$BUCKET" >/dev/null
echo "kv/services/minio-frontend-ci updated (readable by the colatro-ci policy)."

step "Done"
echo "The frontend CI can now mc-mirror dist/ INTO $BUCKET on merge."
