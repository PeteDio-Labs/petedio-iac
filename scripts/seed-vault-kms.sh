#!/usr/bin/env bash
# seed-vault-kms.sh — create the AWS KMS key and the IAM user that Vault on 223 auto-unseals with.
#
# WHY A SCRIPT, NOT TERRAFORM. Same reason as seed-aws-ci.sh: a key Terraform makes would sit in its
# state, and the aws-apply path applies only roots it already has users for. The script creates one
# KMS key, one alias and one IAM user, and nothing else.
#
# WHAT IT CREATES.
#   KMS key       alias/petedio-vault-seal, symmetric, rotation on. The key policy lets the account
#                 admin manage it and lets the seal user Encrypt, Decrypt and DescribeKey only.
#   IAM user      petedio-vault-seal, with one inline policy: those three actions on that key,
#                 and only when the call comes from the lab's public address ($SEAL_SOURCE_IP).
#   Access key    stored in the macOS Keychain items vault-seal-aws-key-id and
#                 vault-seal-aws-secret. NOT in Vault: Vault cannot hold the key that opens Vault.
#                 scripts/deploy-vault-seal.sh carries it to 223.
#
# ⚠ THE KEY IS THE VAULT. Deleting or disabling this KMS key stops Vault from unsealing, which is
# also the emergency brake. AWS refuses an immediate delete: the shortest window is 7 days, and the
# script requests nothing shorter than the default. Never run ScheduleKeyDeletion by hand.
#
# ⚠ THE LAB'S PUBLIC ADDRESS CAN CHANGE. A seal call from any other address is denied, so a new
# address leaves a restarted Vault sealed. After a change, run this script with --update-ip.
#
#   AWS: a profile for the account that can create IAM users and KMS keys (--profile NAME).
#
# Usage:
#   ./scripts/seed-vault-kms.sh --profile <profile>               # create
#   ./scripts/seed-vault-kms.sh --profile <profile> --update-ip   # re-pin to the current address
set -euo pipefail
umask 077

PROFILE=""; UPDATE_IP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="${2:?--profile needs a name}"; shift 2 ;;
    --update-ip) UPDATE_IP=1; shift ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
[ -n "$PROFILE" ] || { echo "ABORT: pass --profile <aws profile>." >&2; exit 2; }

REGION="us-east-2"
ALIAS="alias/petedio-vault-seal"
USER_NAME="petedio-vault-seal"
POLICY_NAME="vault-seal-kms-use"
ID_ITEM="vault-seal-aws-key-id"
SECRET_ITEM="vault-seal-aws-secret"

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }
for t in aws jq curl security; do command -v "$t" >/dev/null || die "$t not in PATH."; done
aws_(){ aws --profile "$PROFILE" --region "$REGION" --no-cli-pager "$@"; }

step "Read the account and the lab's public address"
ACCT="$(aws_ sts get-caller-identity --query Account --output text)"
SOURCE_IP="${SEAL_SOURCE_IP:-$(curl -fsS --max-time 8 https://checkip.amazonaws.com | tr -d '[:space:]')}"
printf '%s' "$SOURCE_IP" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || die "could not read a public IPv4 address (got '$SOURCE_IP'). Run this from the lab's network, or set SEAL_SOURCE_IP."
printf 'account %s, source %s\n' "$ACCT" "$SOURCE_IP"

step "Find or create the KMS key"
KEY_ID="$(aws_ kms describe-key --key-id "$ALIAS" --query KeyMetadata.KeyId --output text 2>/dev/null || true)"
if [ -z "$KEY_ID" ] || [ "$KEY_ID" = "None" ]; then
  [ "$UPDATE_IP" -eq 0 ] || die "--update-ip found no key $ALIAS. Run without it first."
  KEY_ID="$(aws_ kms create-key --description "Vault auto-unseal (PeteDio lab)" --key-usage ENCRYPT_DECRYPT \
    --query KeyMetadata.KeyId --output text)"
  aws_ kms create-alias --alias-name "$ALIAS" --target-key-id "$KEY_ID"
  aws_ kms enable-key-rotation --key-id "$KEY_ID"
  echo "created key $KEY_ID"
else
  echo "key exists: $KEY_ID"
fi
KEY_ARN="arn:aws:kms:$REGION:$ACCT:key/$KEY_ID"

step "Create the IAM user"
aws_ iam get-user --user-name "$USER_NAME" >/dev/null 2>&1 || aws_ iam create-user --user-name "$USER_NAME" >/dev/null
USER_ARN="arn:aws:iam::$ACCT:user/$USER_NAME"

step "Write the key policy and the user policy"
KEY_POLICY="$(jq -n --arg acct "$ACCT" --arg user "$USER_ARN" '{Version:"2012-10-17",Statement:[
  {Sid:"AccountAdmin",Effect:"Allow",Principal:{AWS:("arn:aws:iam::"+$acct+":root")},Action:"kms:*",Resource:"*"},
  {Sid:"VaultSealUse",Effect:"Allow",Principal:{AWS:$user},Action:["kms:Encrypt","kms:Decrypt","kms:DescribeKey"],Resource:"*"}]}')"
aws_ kms put-key-policy --key-id "$KEY_ID" --policy-name default --policy "$KEY_POLICY"
USER_POLICY="$(jq -n --arg arn "$KEY_ARN" --arg ip "$SOURCE_IP" '{Version:"2012-10-17",Statement:[
  {Effect:"Allow",Action:["kms:Encrypt","kms:Decrypt","kms:DescribeKey"],Resource:$arn,
   Condition:{IpAddress:{"aws:SourceIp":($ip+"/32")}}}]}')"
aws_ iam put-user-policy --user-name "$USER_NAME" --policy-name "$POLICY_NAME" --policy-document "$USER_POLICY"
echo "pinned to $SOURCE_IP/32"

if [ "$UPDATE_IP" -eq 1 ]; then step "Done (address updated)"; exit 0; fi

step "Create the access key and store it in the Keychain"
if security find-generic-password -s "$ID_ITEM" >/dev/null 2>&1; then
  echo "Keychain already holds $ID_ITEM; leaving the key alone. Delete the item and the AWS key to rotate."
else
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  aws_ iam create-access-key --user-name "$USER_NAME" > "$TMP/k.json"
  # `security -i` reads its commands from stdin, so the values stay out of argv and `ps`.
  { printf 'add-generic-password -a vault-223 -s %s -w "%s" -U\n' "$ID_ITEM" "$(jq -r .AccessKey.AccessKeyId "$TMP/k.json")"
    printf 'add-generic-password -a vault-223 -s %s -w "%s" -U\n' "$SECRET_ITEM" "$(jq -r .AccessKey.SecretAccessKey "$TMP/k.json")"
  } | security -i
  security find-generic-password -s "$SECRET_ITEM" -w >/dev/null || die "the secret did not read back from the Keychain."
  echo "stored $ID_ITEM and $SECRET_ITEM"
fi

step "Done"
printf 'Key id for the seal block: %s\n' "$KEY_ID"
echo "Next: scripts/deploy-vault-seal.sh --key-id $KEY_ID, then the migration in docs/runbooks/vault-kms-seal.md."
