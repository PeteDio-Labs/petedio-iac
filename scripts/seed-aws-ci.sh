#!/usr/bin/env bash
# seed-aws-ci.sh — create the IAM users that aws-apply.yml plans and applies with, and store their
# keys in Vault (PET-942).
#
# WHY A SCRIPT, NOT TERRAFORM. The users below are what Terraform runs as, so no apply of theirs
# can exist before they do. The account's service control policy also denies an IAM OIDC provider
# (PET-816), so a job cannot assume a role and needs a stored key. The script is the smallest
# imperative residue: it creates users, policies and keys, and nothing else. A Terraform root for
# the users would still need these keys placed in Vault, and a key made by Terraform sits in its
# state, so the script keeps users, policies and keys together, as seed-aws-portfolio-plan.sh does.
#
# Per root (dashboard, portfolio, authentik) it creates:
#   petedio-ci-<root>-plan    ReadOnlyAccess. Key -> kv/services/aws-ci/<root>-plan
#   petedio-ci-<root>-apply   a managed policy of the same name that names that root's resources.
#                             Key -> kv/services/aws-ci/<root>-apply
# plus a MinIO service account for the Terraform state, in the same Vault entry: read-only on
# tfstate/<root>/* for plan, read and write there for apply. Neither is the shared kv/iac/minio key.
# MinIO admin credentials are used here only and never written to Vault:
# $MINIO_ROOT_USER/$MINIO_ROOT_PASSWORD, else $MINIO_CREDS_FILE, else a prompt.
# and the permissions boundary petedio-dashboard-boundary, which the dashboard apply must attach
# to every IAM user or role it creates.
#
# Keys go from the AWS CLI into a 0700 temporary directory and then into Vault. They never reach
# argv or the screen. Without --rotate the script creates a key only when Vault holds none.
# --rotate stores a new key, reads it back, and only then deletes the old one.
#
#   AWS: a profile for account 847547470418 that can create IAM users (--profile NAME).
#   Vault token: $VAULT_TOKEN, else the macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM.
#
# Usage:
#   ./scripts/seed-aws-ci.sh --profile <profile>
#   ./scripts/seed-aws-ci.sh --profile <profile> --rotate
set -euo pipefail
umask 077

PROFILE=""; ROTATE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="${2:?--profile needs a name}"; shift 2 ;;
    --rotate) ROTATE=1; shift ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
[ -n "$PROFILE" ] || { echo "ABORT: pass --profile <aws profile>." >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ACCT="847547470418"
BND="arn:aws:iam::$ACCT:policy/petedio-dashboard-boundary"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"
MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://192.168.50.221:9000}"
MINIO_CREDS_FILE="${MINIO_CREDS_FILE:-$HOME/petedio/.secrets/minio-221.txt}"
export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$REPO_ROOT/environments/homelab/vault-ca.crt}"

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }
for t in aws vault jq mc; do command -v "$t" >/dev/null || die "$t not in PATH."; done
aws_(){ aws --profile "$PROFILE" --no-cli-pager "$@"; }

step "AWS"
GOT="$(aws_ sts get-caller-identity --query Account --output text 2>/dev/null || true)"
[ "$GOT" = "$ACCT" ] || die "profile '$PROFILE' is account '${GOT:-unreadable}', not $ACCT."
echo "  account $ACCT"

step "Vault"
if [ -z "${VAULT_TOKEN:-}" ] && command -v security >/dev/null; then
  VAULT_TOKEN="$(security find-generic-password -s "$VAULT_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null || true)"
fi
[ -n "${VAULT_TOKEN:-}" ] || die "no VAULT_TOKEN and no Keychain item '$VAULT_TOKEN_KEYCHAIN_ITEM'."
export VAULT_TOKEN
vault token lookup >/dev/null 2>&1 || die "the Vault token is invalid, or Vault is sealed. Run scripts/pet-secrets doctor."

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

step "MinIO admin (used here only, never written to Vault)"
MROOT_U="${MINIO_ROOT_USER:-}"; MROOT_P="${MINIO_ROOT_PASSWORD:-}"
if { [ -z "$MROOT_U" ] || [ -z "$MROOT_P" ]; } && [ -f "$MINIO_CREDS_FILE" ]; then
  cred(){ python3 "$SCRIPT_DIR/minio-cred.py" "$MINIO_CREDS_FILE" "$1" || true; }
  [ -n "$MROOT_U" ] || MROOT_U="$(cred ROOT_USER)"
  [ -n "$MROOT_P" ] || MROOT_P="$(cred ROOT_PASSWORD)"
fi
[ -n "$MROOT_U" ] || read -rp "  MinIO admin user: " MROOT_U
[ -n "$MROOT_P" ] || { read -rsp "  MinIO admin password (hidden): " MROOT_P; echo; }
mkdir -p "$TMP/mc"
m(){ mc --config-dir "$TMP/mc" "$@"; }
# `mc alias set` reads both keys from stdin, and printf is a builtin, so neither reaches argv.
printf '%s\n%s\n' "$MROOT_U" "$MROOT_P" | m alias set adm "$MINIO_ENDPOINT" --api s3v4 --path auto >/dev/null 2>&1 \
  && m ls adm >/dev/null 2>&1 \
  || die "$MINIO_ENDPOINT rejected the admin credential, or it is unreachable (is this machine on the .50 LAN?)."
echo "  authenticated (user length ${#MROOT_U})"

# ── Policies ─────────────────────────────────────────────────────────────────────────────────
# Every Resource below names a root's own resources. Some services cannot be named before the
# resource exists, because AWS generates the identifier, so those are scoped to the account and
# region instead. A few create actions accept only Resource "*" (CreateNeedsStar); the deny list
# and the workflow's refusal of any delete bound what they can do. Each is called out where it appears.
cat > "$TMP/boundary.json" <<JSON
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":["dynamodb:GetItem","dynamodb:PutItem","dynamodb:Query"],"Resource":"arn:aws:dynamodb:*:$ACCT:table/dash"},
 {"Effect":"Allow","Action":["logs:CreateLogStream","logs:PutLogEvents"],"Resource":"arn:aws:logs:*:$ACCT:log-group:/aws/lambda/petedio-dash-*:*"},
 {"Effect":"Allow","Action":"execute-api:Invoke","Resource":"arn:aws:execute-api:*:$ACCT:*"},
 {"Effect":"Allow","Action":["s3:PutObject","s3:DeleteObject","s3:GetObject","s3:ListBucket"],"Resource":["arn:aws:s3:::petedio-dash-site-$ACCT","arn:aws:s3:::petedio-dash-site-$ACCT/*"]},
 {"Effect":"Allow","Action":["lambda:UpdateFunctionCode","lambda:GetFunction","lambda:GetFunctionConfiguration"],"Resource":"arn:aws:lambda:*:$ACCT:function:petedio-dash-api"},
 {"Effect":"Allow","Action":["cloudfront:CreateInvalidation","cloudfront:GetInvalidation"],"Resource":"arn:aws:cloudfront::$ACCT:distribution/*"}
]}
JSON

cat > "$TMP/dashboard-apply.json" <<JSON
{"Version":"2012-10-17","Statement":[
 {"Sid":"Read","Effect":"Allow","Action":["iam:Get*","iam:List*","sts:GetCallerIdentity","s3:ListAllMyBuckets","route53:Get*","route53:List*","acm:Describe*","acm:List*","acm:Get*","cloudfront:Get*","cloudfront:List*","logs:DescribeLogGroups","logs:ListTagsForResource","logs:ListTagsLogGroup","apigateway:GET","cognito-idp:Describe*","cognito-idp:List*","cognito-idp:Get*","lambda:Get*","lambda:List*","dynamodb:Describe*","dynamodb:List*"],"Resource":"*"},
 {"Sid":"CreateNeedsStar","Effect":"Allow","Action":["cloudfront:CreateDistribution","cloudfront:CreateOriginAccessControl","cloudfront:CreateFunction","cloudfront:CreateResponseHeadersPolicy","cloudfront:TagResource","cognito-idp:CreateUserPool","route53:CreateHostedZone","route53:CreateHealthCheck","acm:RequestCertificate"],"Resource":"*"},
 {"Sid":"Bucket","Effect":"Allow","Action":"s3:*","Resource":["arn:aws:s3:::petedio-dash-site-$ACCT","arn:aws:s3:::petedio-dash-site-$ACCT/*"]},
 {"Sid":"Lambda","Effect":"Allow","Action":"lambda:*","Resource":"arn:aws:lambda:us-east-2:$ACCT:function:petedio-dash-*"},
 {"Sid":"Table","Effect":"Allow","Action":"dynamodb:*","Resource":["arn:aws:dynamodb:us-east-2:$ACCT:table/dash","arn:aws:dynamodb:us-east-2:$ACCT:table/dash/*"]},
 {"Sid":"Logs","Effect":"Allow","Action":"logs:*","Resource":["arn:aws:logs:us-east-2:$ACCT:log-group:/aws/lambda/petedio-dash-*","arn:aws:logs:us-east-2:$ACCT:log-group:/aws/lambda/petedio-dash-*:*","arn:aws:logs:us-east-2:$ACCT:log-group:/aws/apigateway/petedio-dash*","arn:aws:logs:us-east-2:$ACCT:log-group:/aws/apigateway/petedio-dash*:*"]},
 {"Sid":"ApiAccountRegionScoped","Effect":"Allow","Action":"apigateway:*","Resource":"arn:aws:apigateway:us-east-2::/*"},
 {"Sid":"CloudFrontAccountScoped","Effect":"Allow","Action":"cloudfront:*","Resource":"arn:aws:cloudfront::$ACCT:*"},
 {"Sid":"CognitoAccountRegionScoped","Effect":"Allow","Action":"cognito-idp:*","Resource":"arn:aws:cognito-idp:us-east-2:$ACCT:userpool/*"},
 {"Sid":"Zones","Effect":"Allow","Action":"route53:*","Resource":["arn:aws:route53:::hostedzone/*","arn:aws:route53:::change/*","arn:aws:route53:::healthcheck/*"]},
 {"Sid":"Certificates","Effect":"Allow","Action":"acm:*","Resource":"arn:aws:acm:us-east-1:$ACCT:certificate/*"},
 {"Sid":"IamNamedOnly","Effect":"Allow","Action":["iam:CreateUser","iam:CreateRole","iam:CreatePolicy","iam:PutRolePolicy","iam:PutUserPolicy","iam:AttachRolePolicy","iam:AttachUserPolicy","iam:PutUserPermissionsBoundary","iam:PutRolePermissionsBoundary","iam:TagUser","iam:TagRole","iam:TagPolicy","iam:UpdateAssumeRolePolicy","iam:CreatePolicyVersion","iam:DeletePolicyVersion","iam:DeleteUserPolicy","iam:DeleteRolePolicy","iam:DetachUserPolicy","iam:DetachRolePolicy"],
  "Resource":["arn:aws:iam::$ACCT:user/petedio-dash-*","arn:aws:iam::$ACCT:role/petedio-dash-*","arn:aws:iam::$ACCT:policy/petedio-dash-*"]},
 {"Sid":"PassToServices","Effect":"Allow","Action":"iam:PassRole","Resource":"arn:aws:iam::$ACCT:role/petedio-dash-*","Condition":{"StringEquals":{"iam:PassedToService":["lambda.amazonaws.com","apigateway.amazonaws.com"]}}},
 {"Sid":"BoundaryRequired","Effect":"Deny","Action":["iam:CreateUser","iam:CreateRole","iam:PutUserPermissionsBoundary","iam:PutRolePermissionsBoundary"],"Resource":"*","Condition":{"StringNotEquals":{"iam:PermissionsBoundary":"$BND"}}},
 {"Sid":"BoundaryStays","Effect":"Deny","Action":["iam:DeleteUserPermissionsBoundary","iam:DeleteRolePermissionsBoundary"],"Resource":"*"},
 {"Sid":"NoDeletes","Effect":"Deny","Action":["iam:DeleteUser","iam:DeleteRole","iam:DeletePolicy","dynamodb:DeleteTable","s3:DeleteBucket","route53:DeleteHostedZone","cognito-idp:DeleteUserPool","lambda:DeleteFunction","cloudfront:DeleteDistribution","acm:DeleteCertificate"],"Resource":"*"}
]}
JSON

cat > "$TMP/portfolio-apply.json" <<JSON
{"Version":"2012-10-17","Statement":[
 {"Sid":"Read","Effect":"Allow","Action":["iam:Get*","iam:List*","sts:GetCallerIdentity","s3:ListAllMyBuckets","acm:Describe*","acm:List*","acm:Get*","cloudfront:Get*","cloudfront:List*"],"Resource":"*"},
 {"Sid":"CreateNeedsStar","Effect":"Allow","Action":["cloudfront:CreateDistribution","cloudfront:CreateOriginAccessControl","cloudfront:CreateFunction","cloudfront:CreateResponseHeadersPolicy","cloudfront:TagResource","acm:RequestCertificate"],"Resource":"*"},
 {"Sid":"Bucket","Effect":"Allow","Action":"s3:*","Resource":["arn:aws:s3:::petedio-portfolio-site-$ACCT","arn:aws:s3:::petedio-portfolio-site-$ACCT/*"]},
 {"Sid":"CloudFrontAccountScoped","Effect":"Allow","Action":"cloudfront:*","Resource":"arn:aws:cloudfront::$ACCT:*"},
 {"Sid":"Certificates","Effect":"Allow","Action":"acm:*","Resource":"arn:aws:acm:us-east-1:$ACCT:certificate/*"},
 {"Sid":"NoDeletes","Effect":"Deny","Action":["s3:DeleteBucket","cloudfront:DeleteDistribution","acm:DeleteCertificate","iam:DeleteUser"],"Resource":"*"}
]}
JSON

# Authentik on AWS (PET-932). The boundary caps the host role: its own parameters, its own bucket,
# and the calls the SSM agent makes. The apply policy may create only petedio-authentik-* IAM names,
# and a role only with that boundary.
ABND="arn:aws:iam::$ACCT:policy/petedio-authentik-boundary"
cat > "$TMP/authentik-boundary.json" <<JSON
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":["ssm:GetParameter","ssm:GetParameters","ssm:GetParametersByPath"],"Resource":"arn:aws:ssm:us-east-2:$ACCT:parameter/petedio-authentik/*"},
 {"Effect":"Allow","Action":"kms:Decrypt","Resource":"*","Condition":{"StringEquals":{"kms:ViaService":"ssm.us-east-2.amazonaws.com"}}},
 {"Effect":"Allow","Action":["s3:ListBucket","s3:GetObject","s3:PutObject"],"Resource":["arn:aws:s3:::petedio-authentik-$ACCT","arn:aws:s3:::petedio-authentik-$ACCT/*"]},
 {"Effect":"Allow","Action":["ssm:UpdateInstanceInformation","ssm:ListInstanceAssociations","ssm:ListAssociations","ssm:DescribeAssociation","ssm:GetDocument","ssm:DescribeDocument","ssm:UpdateInstanceAssociationStatus","ssm:PutInventory","ssmmessages:*","ec2messages:*"],"Resource":"*"}
]}
JSON

cat > "$TMP/authentik-apply.json" <<JSON
{"Version":"2012-10-17","Statement":[
 {"Sid":"Read","Effect":"Allow","Action":["iam:Get*","iam:List*","sts:GetCallerIdentity","s3:ListAllMyBuckets","ec2:Describe*","ec2:Get*"],"Resource":"*"},
 {"Sid":"AmiParameter","Effect":"Allow","Action":["ssm:GetParameter","ssm:GetParameters"],"Resource":"arn:aws:ssm:us-east-2::parameter/aws/service/*"},
 {"Sid":"Ec2RegionScoped","Effect":"Allow","Action":"ec2:*","Resource":"*","Condition":{"StringEquals":{"aws:RequestedRegion":"us-east-2"}}},
 {"Sid":"Bucket","Effect":"Allow","Action":"s3:*","Resource":["arn:aws:s3:::petedio-authentik-$ACCT","arn:aws:s3:::petedio-authentik-$ACCT/*"]},
 {"Sid":"IamNamedOnly","Effect":"Allow","Action":["iam:CreateRole","iam:PutRolePolicy","iam:DeleteRolePolicy","iam:TagRole","iam:UntagRole","iam:UpdateAssumeRolePolicy","iam:PutRolePermissionsBoundary","iam:CreateInstanceProfile","iam:AddRoleToInstanceProfile","iam:TagInstanceProfile"],
  "Resource":["arn:aws:iam::$ACCT:role/petedio-authentik-*","arn:aws:iam::$ACCT:instance-profile/petedio-authentik-*"]},
 {"Sid":"SsmCoreOnly","Effect":"Allow","Action":["iam:AttachRolePolicy","iam:DetachRolePolicy"],"Resource":"arn:aws:iam::$ACCT:role/petedio-authentik-*","Condition":{"ArnEquals":{"iam:PolicyARN":"arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"}}},
 {"Sid":"PassToEc2","Effect":"Allow","Action":"iam:PassRole","Resource":"arn:aws:iam::$ACCT:role/petedio-authentik-*","Condition":{"StringEquals":{"iam:PassedToService":"ec2.amazonaws.com"}}},
 {"Sid":"BoundaryRequired","Effect":"Deny","Action":["iam:CreateRole","iam:PutRolePermissionsBoundary"],"Resource":"*","Condition":{"StringNotEquals":{"iam:PermissionsBoundary":"$ABND"}}},
 {"Sid":"BoundaryStays","Effect":"Deny","Action":"iam:DeleteRolePermissionsBoundary","Resource":"*"},
 {"Sid":"NoDeletes","Effect":"Deny","Action":["iam:DeleteRole","iam:DeleteInstanceProfile","s3:DeleteBucket","ec2:TerminateInstances","ec2:DeleteVpc","ec2:DeleteVolume"],"Resource":"*"}
]}
JSON

step "Boundary policy petedio-authentik-boundary"
if aws_ iam get-policy --policy-arn "$ABND" >/dev/null 2>&1; then
  for v in $(aws_ iam list-policy-versions --policy-arn "$ABND" --query 'Versions[?!IsDefaultVersion].VersionId' --output text); do aws_ iam delete-policy-version --policy-arn "$ABND" --version-id "$v"; done
  aws_ iam create-policy-version --policy-arn "$ABND" --policy-document "file://$TMP/authentik-boundary.json" --set-as-default >/dev/null
  echo "  updated"
else
  aws_ iam create-policy --policy-name petedio-authentik-boundary --policy-document "file://$TMP/authentik-boundary.json" >/dev/null
  echo "  created"
fi

step "Boundary policy petedio-dashboard-boundary"
if aws_ iam get-policy --policy-arn "$BND" >/dev/null 2>&1; then
  for v in $(aws_ iam list-policy-versions --policy-arn "$BND" --query 'Versions[?!IsDefaultVersion].VersionId' --output text); do aws_ iam delete-policy-version --policy-arn "$BND" --version-id "$v"; done
  aws_ iam create-policy-version --policy-arn "$BND" --policy-document "file://$TMP/boundary.json" --set-as-default >/dev/null
  echo "  updated"
else
  aws_ iam create-policy --policy-name petedio-dashboard-boundary --policy-document "file://$TMP/boundary.json" >/dev/null
  echo "  created"
fi

mint(){ # $1 root, $2 kind (plan|apply)
  local root="$1" kind="$2" user="petedio-ci-$1-$2" kv="kv/services/aws-ci/$1-$2" old new
  step "IAM user $user"
  aws_ iam get-user --user-name "$user" >/dev/null 2>&1 \
    || aws_ iam create-user --user-name "$user" --tags Key=project,Value=petedio-"$root" Key=purpose,Value=ci-"$kind" >/dev/null
  if [ "$kind" = plan ]; then
    aws_ iam attach-user-policy --user-name "$user" --policy-arn arn:aws:iam::aws:policy/ReadOnlyAccess
  else
    # A managed policy, not an inline one: an IAM user's inline policies share a 2,048-character
    # limit, and the dashboard policy is larger. A managed policy allows 6,144.
    local parn="arn:aws:iam::$ACCT:policy/petedio-ci-$root-apply" v
    if aws_ iam get-policy --policy-arn "$parn" >/dev/null 2>&1; then
      for v in $(aws_ iam list-policy-versions --policy-arn "$parn" --query 'Versions[?!IsDefaultVersion].VersionId' --output text); do aws_ iam delete-policy-version --policy-arn "$parn" --version-id "$v"; done
      aws_ iam create-policy-version --policy-arn "$parn" --policy-document "file://$TMP/$root-apply.json" --set-as-default >/dev/null
    else
      aws_ iam create-policy --policy-name "petedio-ci-$root-apply" --policy-document "file://$TMP/$root-apply.json" >/dev/null
    fi
    aws_ iam attach-user-policy --user-name "$user" --policy-arn "$parn"
  fi
  echo "  policy set"
  if [ "$ROTATE" -eq 0 ] && vault kv get -field=aws_access_key_id "$kv" >/dev/null 2>&1; then
    echo "  $kv already holds a key. Nothing to do; pass --rotate to replace it."
    return 0
  fi
  old="$(aws_ iam list-access-keys --user-name "$user" --query 'AccessKeyMetadata[].AccessKeyId' --output text)"
  [ "$(printf '%s' "$old" | wc -w | tr -d ' ')" -lt 2 ] || die "$user already has two keys. Delete one in IAM, then run this again."
  aws_ iam create-access-key --user-name "$user" --output json > "$TMP/key.json"
  new="$(jq -r '.AccessKey.AccessKeyId' "$TMP/key.json")"
  jq '{aws_access_key_id: .AccessKey.AccessKeyId, aws_secret_access_key: .AccessKey.SecretAccessKey}' "$TMP/key.json" > "$TMP/data.json"
  local oldm macc
  oldm="$(vault kv get -field=minio_access_key "$kv" 2>/dev/null || true)"
  if [ "$kind" = plan ]; then
    printf '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:ListBucket","s3:GetBucketLocation"],"Resource":["arn:aws:s3:::tfstate"]},{"Effect":"Allow","Action":["s3:GetObject"],"Resource":["arn:aws:s3:::tfstate/%s/*"]}]}' "$root" > "$TMP/minio-policy.json"
  else
    printf '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:ListBucket","s3:GetBucketLocation"],"Resource":["arn:aws:s3:::tfstate"]},{"Effect":"Allow","Action":["s3:GetObject","s3:PutObject","s3:DeleteObject"],"Resource":["arn:aws:s3:::tfstate/%s/*"]}]}' "$root" > "$TMP/minio-policy.json"
  fi
  m admin user svcacct add --policy "$TMP/minio-policy.json" --json adm "$MROOT_U" > "$TMP/minio-key.json"
  macc="$(jq -r '.accessKey // empty' "$TMP/minio-key.json")"
  [ -n "$macc" ] && [ -n "$(jq -r '.secretKey // empty' "$TMP/minio-key.json")" ] || die "could not mint or parse the MinIO service account. Delete key $new on $user in IAM."
  jq -n --slurpfile a "$TMP/key.json" --slurpfile mk "$TMP/minio-key.json" '{aws_access_key_id: $a[0].AccessKey.AccessKeyId, aws_secret_access_key: $a[0].AccessKey.SecretAccessKey, minio_access_key: $mk[0].accessKey, minio_secret_key: $mk[0].secretKey}' > "$TMP/data.json"
  vault kv put "$kv" @"$TMP/data.json" >/dev/null || die "Vault write failed. Delete key $new on $user in IAM and service account $macc in MinIO; old credentials are unchanged."
  [ "$(vault kv get -field=aws_access_key_id "$kv")" = "$new" ] && [ "$(vault kv get -field=minio_access_key "$kv")" = "$macc" ] || die "Vault read-back for $kv does not match. Stop; do not revoke anything."
  echo "  stored in $kv and read back (values not shown)"
  for k in $old; do [ "$k" = "$new" ] || aws_ iam delete-access-key --user-name "$user" --access-key-id "$k"; done
  if [ -n "$oldm" ] && [ "$oldm" != "$macc" ]; then m admin user svcacct rm adm "$oldm" >/dev/null 2>&1 || echo "  could not remove the old MinIO service account $oldm; remove it by hand"; fi
  rm -f "$TMP/key.json" "$TMP/data.json" "$TMP/minio-key.json"
}
for root in dashboard portfolio authentik; do mint "$root" plan; mint "$root" apply; done

step "Done"
echo "  4 IAM users, 4 MinIO service accounts and the boundary policy exist, and Vault holds 4 entries under kv/services/aws-ci/."
echo "  Tell the thread: seed finished. No value was printed."
