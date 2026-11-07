#!/usr/bin/env bash
# seed-aws-portfolio-plan.sh — create the read-only IAM user that portfolio-plan.yml plans with,
# and store its access key in kv/services/aws-portfolio-plan (PET-884).
#
#   IAM user   petedio-portfolio-plan, with one inline policy of Get/List/Describe actions
#              for the services environments/portfolio manages (S3, CloudFront, ACM, IAM).
#   Vault      kv/services/aws-portfolio-plan: aws_access_key_id, aws_secret_access_key
#
# The key goes from `aws iam create-access-key` into a 0700 temporary directory and then into
# Vault. It never reaches argv or the screen. The script is idempotent: with no flag it creates
# the user and a key only when Vault holds none. --rotate replaces the key.
#
#   AWS: a profile for account 847547470418 that can create IAM users (--profile NAME).
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
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
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
export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$REPO_ROOT/environments/homelab/vault-ca.crt}"

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }
for t in aws vault jq; do command -v "$t" >/dev/null || die "$t not in PATH."; done

step "AWS"
GOT="$(aws --profile "$PROFILE" sts get-caller-identity --query Account --output text 2>/dev/null || true)"
[ "$GOT" = "$ACCOUNT" ] || die "profile '$PROFILE' is account '${GOT:-unreadable}', not $ACCOUNT. Run aws login for the portfolio account."
echo "  account $ACCOUNT"

step "Vault"
if [ -z "${VAULT_TOKEN:-}" ] && command -v security >/dev/null; then
  VAULT_TOKEN="$(security find-generic-password -s "$VAULT_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null || true)"
fi
[ -n "${VAULT_TOKEN:-}" ] || die "no VAULT_TOKEN and no Keychain item '$VAULT_TOKEN_KEYCHAIN_ITEM'."
export VAULT_TOKEN
vault token lookup >/dev/null 2>&1 || die "the Vault token is invalid, or Vault is sealed. Run scripts/pet-secrets doctor."
if [ "$ROTATE" -eq 0 ] && vault kv get -field=aws_access_key_id "$PATH_KV" >/dev/null 2>&1; then
  echo "  $PATH_KV already holds a key. Nothing to do; pass --rotate to replace it."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/policy.json" <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "PlanReadOnly",
    "Effect": "Allow",
    "Action": [
      "s3:GetBucket*", "s3:ListBucket", "s3:ListAllMyBuckets", "s3:GetAccelerateConfiguration",
      "s3:GetEncryptionConfiguration", "s3:GetLifecycleConfiguration", "s3:GetReplicationConfiguration",
      "s3:GetAccountPublicAccessBlock",
      "cloudfront:Get*", "cloudfront:List*",
      "acm:Describe*", "acm:Get*", "acm:List*",
      "iam:Get*", "iam:List*",
      "sts:GetCallerIdentity"
    ],
    "Resource": "*"
  }]
}
JSON

step "IAM user $USER_NAME"
if aws --profile "$PROFILE" iam get-user --user-name "$USER_NAME" >/dev/null 2>&1; then
  echo "  exists"
else
  aws --profile "$PROFILE" iam create-user --user-name "$USER_NAME" --tags Key=project,Value=petedio-portfolio Key=purpose,Value=plan-read-only >/dev/null
  echo "  created"
fi
aws --profile "$PROFILE" iam put-user-policy --user-name "$USER_NAME" --policy-name PlanReadOnly --policy-document "file://$TMP/policy.json"
echo "  inline policy PlanReadOnly set"

step "Access key"
if [ "$ROTATE" -eq 1 ]; then
  for k in $(aws --profile "$PROFILE" iam list-access-keys --user-name "$USER_NAME" --query 'AccessKeyMetadata[].AccessKeyId' --output text); do
    aws --profile "$PROFILE" iam delete-access-key --user-name "$USER_NAME" --access-key-id "$k"
  done
  echo "  old keys deleted"
fi
N="$(aws --profile "$PROFILE" iam list-access-keys --user-name "$USER_NAME" --query 'length(AccessKeyMetadata)' --output text)"
[ "$N" -lt 2 ] || die "$USER_NAME already has $N keys. Delete one in IAM, or run with --rotate."
aws --profile "$PROFILE" iam create-access-key --user-name "$USER_NAME" --output json \
  | jq '{aws_access_key_id: .AccessKey.AccessKeyId, aws_secret_access_key: .AccessKey.SecretAccessKey}' > "$TMP/data.json"
vault kv put "$PATH_KV" @"$TMP/data.json" >/dev/null
echo "  stored in $PATH_KV (value not shown)"
vault kv get -field=aws_access_key_id "$PATH_KV" | sed -E 's/^(.{4}).*/  access key id begins \1.../'

step "Done"
echo "  Next: apply vault-config for the portfolio-plan role, then dispatch the portfolio-plan workflow."
