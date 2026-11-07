#!/usr/bin/env bash
# seed-aws-portfolio-plan.sh — create the read-only credentials that portfolio-plan.yml plans
# with, and store them in kv/services/aws-portfolio-plan (PET-884).
#
#   IAM user   petedio-portfolio-plan, with the inline policy in scripts/aws-portfolio-plan-policy.json
#              (Get/List/Describe actions for S3, CloudFront, ACM and IAM).
#   MinIO      a service account that can only read tfstate/portfolio/*, so a leaked token cannot
#              overwrite or delete any root's state. It is not the shared kv/iac/minio key.
#   Vault      kv/services/aws-portfolio-plan: aws_access_key_id, aws_secret_access_key,
#              minio_access_key, minio_secret_key
#
# Keys go from the AWS and MinIO CLIs into a 0700 temporary directory and then into Vault. They
# never reach argv or the screen. With no flag the script creates the credentials only when Vault
# holds none. --rotate creates replacements, stores them, reads them back, and only then revokes
# the old AWS key and MinIO service account, so a failed step leaves the working credentials.
#
#   AWS: a profile for account 847547470418 that can create IAM users (--profile NAME).
#   MinIO admin: $MINIO_ROOT_USER/$MINIO_ROOT_PASSWORD, else $MINIO_CREDS_FILE, else a prompt.
#   Vault token: $VAULT_TOKEN, else the macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM.
#
# Usage:
#   ./scripts/seed-aws-portfolio-plan.sh --profile <profile>
#   ./scripts/seed-aws-portfolio-plan.sh --profile <profile> --rotate
set -euo pipefail
umask 077

PROFILE=""; ROTATE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="${2:?--profile needs a name}"; shift 2 ;;
    --rotate) ROTATE=1; shift ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
[ -n "$PROFILE" ] || { echo "ABORT: pass --profile <aws profile>." >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PATH_KV="kv/services/aws-portfolio-plan"
USER_NAME="petedio-portfolio-plan"
ACCOUNT="847547470418"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"
MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://192.168.50.221:9000}"
MINIO_CREDS_FILE="${MINIO_CREDS_FILE:-$HOME/petedio/.secrets/minio-221.txt}"
export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$REPO_ROOT/environments/homelab/vault-ca.crt}"

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }
for t in aws vault jq mc; do command -v "$t" >/dev/null || die "$t not in PATH."; done
aws_(){ aws --profile "$PROFILE" "$@"; }

step "AWS"
GOT="$(aws_ sts get-caller-identity --query Account --output text 2>/dev/null || true)"
[ "$GOT" = "$ACCOUNT" ] || die "profile '$PROFILE' is account '${GOT:-unreadable}', not $ACCOUNT. Run aws login for the portfolio account."
echo "  account $ACCOUNT"

step "Vault"
if [ -z "${VAULT_TOKEN:-}" ] && command -v security >/dev/null; then
  VAULT_TOKEN="$(security find-generic-password -s "$VAULT_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null || true)"
fi
[ -n "${VAULT_TOKEN:-}" ] || die "no VAULT_TOKEN and no Keychain item '$VAULT_TOKEN_KEYCHAIN_ITEM'."
export VAULT_TOKEN
vault token lookup >/dev/null 2>&1 || die "the Vault token is invalid, or Vault is sealed. Run scripts/pet-secrets doctor."
have(){ vault kv get -field="$1" "$PATH_KV" >/dev/null 2>&1; }
if [ "$ROTATE" -eq 0 ] && have aws_access_key_id && have aws_secret_access_key && have minio_access_key && have minio_secret_key; then
  echo "  $PATH_KV already holds all four fields. Nothing to do; pass --rotate to replace them."
  exit 0
fi
OLD_MINIO_AK="$(vault kv get -field=minio_access_key "$PATH_KV" 2>/dev/null || true)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

step "MinIO admin (used here only, never written to Vault)"
MROOT_U="${MINIO_ROOT_USER:-}"; MROOT_P="${MINIO_ROOT_PASSWORD:-}"
if { [ -z "$MROOT_U" ] || [ -z "$MROOT_P" ]; } && [ -f "$MINIO_CREDS_FILE" ]; then
  MROOT_U="$(grep -iE 'ROOT_USER'     "$MINIO_CREDS_FILE" | head -1 | sed 's/.*[=:][[:space:]]*//' | tr -d ' "'\''')"
  MROOT_P="$(grep -iE 'ROOT_PASSWORD' "$MINIO_CREDS_FILE" | head -1 | sed 's/.*[=:][[:space:]]*//' | tr -d ' "'\''')"
fi
[ -n "$MROOT_U" ] || read -rp  "  MinIO admin user: " MROOT_U
[ -n "$MROOT_P" ] || { read -rsp "  MinIO admin password (hidden): " MROOT_P; echo; }
mc --config-dir "$TMP/mc" alias set adm "$MINIO_ENDPOINT" "$MROOT_U" "$MROOT_P" >/dev/null 2>&1 \
  || die "MinIO admin credentials rejected by $MINIO_ENDPOINT."
echo "  authenticated"

step "IAM user $USER_NAME"
if aws_ iam get-user --user-name "$USER_NAME" >/dev/null 2>&1; then
  echo "  exists"
else
  aws_ iam create-user --user-name "$USER_NAME" --tags Key=project,Value=petedio-portfolio Key=purpose,Value=plan-read-only >/dev/null
  echo "  created"
fi
aws_ iam put-user-policy --user-name "$USER_NAME" --policy-name PlanReadOnly \
  --policy-document "file://$SCRIPT_DIR/aws-portfolio-plan-policy.json"
echo "  inline policy PlanReadOnly set"

step "New AWS access key"
OLD_KEYS="$(aws_ iam list-access-keys --user-name "$USER_NAME" --query 'AccessKeyMetadata[].AccessKeyId' --output text)"
N="$(printf '%s' "$OLD_KEYS" | wc -w | tr -d ' ')"
[ "$N" -lt 2 ] || die "$USER_NAME already has $N keys. Delete one in IAM, then run this again."
aws_ iam create-access-key --user-name "$USER_NAME" --output json > "$TMP/aws-key.json"
NEW_AK="$(jq -r '.AccessKey.AccessKeyId' "$TMP/aws-key.json")"
echo "  created"

step "New MinIO service account (read-only on tfstate/portfolio/*)"
cat > "$TMP/minio-policy.json" <<'JSON'
{ "Version":"2012-10-17","Statement":[
  {"Effect":"Allow","Action":["s3:ListBucket","s3:GetBucketLocation"],"Resource":["arn:aws:s3:::tfstate"]},
  {"Effect":"Allow","Action":["s3:GetObject"],"Resource":["arn:aws:s3:::tfstate/portfolio/*"]}
]}
JSON
mc --config-dir "$TMP/mc" admin user svcacct add --policy "$TMP/minio-policy.json" --json adm "$MROOT_U" > "$TMP/minio-key.json"
M_AK="$(jq -r '.accessKey // empty' "$TMP/minio-key.json")"
[ -n "$M_AK" ] && [ -n "$(jq -r '.secretKey // empty' "$TMP/minio-key.json")" ] || die "could not mint or parse the MinIO service account. Old credentials are unchanged."
echo "  created"

step "Store, then read back"
jq -n --slurpfile a "$TMP/aws-key.json" --slurpfile m "$TMP/minio-key.json" \
  '{aws_access_key_id: $a[0].AccessKey.AccessKeyId, aws_secret_access_key: $a[0].AccessKey.SecretAccessKey,
    minio_access_key: $m[0].accessKey, minio_secret_key: $m[0].secretKey}' > "$TMP/data.json"
vault kv put "$PATH_KV" @"$TMP/data.json" >/dev/null || die "Vault write failed. Old credentials are unchanged; the new ones were not stored. Delete key $NEW_AK in IAM and service account $M_AK in MinIO."
[ "$(vault kv get -field=aws_access_key_id "$PATH_KV")" = "$NEW_AK" ] && [ "$(vault kv get -field=minio_access_key "$PATH_KV")" = "$M_AK" ] \
  || die "Vault read-back does not match the new credentials. Stop; do not revoke anything."
echo "  stored in $PATH_KV and read back (values not shown)"

step "Revoke the old credentials"
for k in $OLD_KEYS; do
  [ "$k" = "$NEW_AK" ] || aws_ iam delete-access-key --user-name "$USER_NAME" --access-key-id "$k"
done
if [ -n "$OLD_MINIO_AK" ] && [ "$OLD_MINIO_AK" != "$M_AK" ]; then
  mc --config-dir "$TMP/mc" admin user svcacct rm adm "$OLD_MINIO_AK" >/dev/null 2>&1 || echo "  could not remove the old MinIO service account $OLD_MINIO_AK; remove it by hand"
fi
echo "  done"

step "Done"
echo "  Next: apply vault-config for the portfolio-plan role, then dispatch the portfolio-plan workflow."
