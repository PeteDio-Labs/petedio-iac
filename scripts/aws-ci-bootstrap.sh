#!/usr/bin/env bash
# Create the AWS side of aws-apply.yml, once (PET-941).
#
# Run it from a Mac with an AWS admin profile for account 847547470418:
#   bash scripts/aws-ci-bootstrap.sh --profile <admin-profile>
# Run it again to update the policies. It places no secret: GitHub proves who it is with an
# OIDC token, so AWS holds no key for the workflow.
#
# It creates, if missing:
#   - the GitHub OIDC identity provider
#   - petedio-dashboard-boundary   (permissions boundary for everything the apply creates)
#   - petedio-ci-dashboard-plan / -apply   (dashboard stack)
#   - petedio-ci-portfolio-plan / -apply   (portfolio site stack; no IAM writes)
# Each plan role has ReadOnlyAccess and trusts main. Each apply role trusts the `lab-write`
# environment only. The offsite-watchdog root stays as it is: it already applies with its own
# boundary-limited IAM user whose key lives in Vault.
set -uo pipefail
PROFILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="${2:-}"; shift 2 ;;
    *) echo "unknown option: $1"; exit 2 ;;
  esac
done
[ -n "$PROFILE" ] || { echo "usage: $0 --profile <aws-admin-profile>"; exit 2; }
ACCT=847547470418
REPO="PeteDio-Labs/petedio-iac"
OIDC="token.actions.githubusercontent.com"
export AWS_PROFILE="$PROFILE" AWS_PAGER=""
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

got="$(aws sts get-caller-identity --query Account --output text 2>&1)" || { echo "ABORT: no AWS access with profile $PROFILE: $got"; exit 1; }
[ "$got" = "$ACCT" ] || { echo "ABORT: profile $PROFILE is account $got, not $ACCT."; exit 1; }

PROV="arn:aws:iam::$ACCT:oidc-provider/$OIDC"
if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$PROV" >/dev/null 2>&1; then
  echo "ok: OIDC provider exists"
else
  aws iam create-open-id-connect-provider --url "https://$OIDC" --client-id-list sts.amazonaws.com \
    --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 >/dev/null || { echo "ABORT: could not create the OIDC provider."; exit 1; }
  echo "created: OIDC provider"
fi

cat > "$T/boundary.json" <<JSON
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":["dynamodb:GetItem","dynamodb:PutItem","dynamodb:Query"],"Resource":"arn:aws:dynamodb:*:$ACCT:table/dash"},
 {"Effect":"Allow","Action":["logs:CreateLogStream","logs:PutLogEvents"],"Resource":"arn:aws:logs:*:$ACCT:log-group:/aws/lambda/petedio-dash-*:*"},
 {"Effect":"Allow","Action":"execute-api:Invoke","Resource":"arn:aws:execute-api:*:$ACCT:*"},
 {"Effect":"Allow","Action":["s3:PutObject","s3:DeleteObject","s3:GetObject","s3:ListBucket"],"Resource":["arn:aws:s3:::petedio-dash-site-$ACCT","arn:aws:s3:::petedio-dash-site-$ACCT/*"]},
 {"Effect":"Allow","Action":["lambda:UpdateFunctionCode","lambda:GetFunction"],"Resource":"arn:aws:lambda:*:$ACCT:function:petedio-dash-api"},
 {"Effect":"Allow","Action":["cloudfront:CreateInvalidation","cloudfront:GetInvalidation"],"Resource":"arn:aws:cloudfront::$ACCT:distribution/*"}
]}
JSON
BND="arn:aws:iam::$ACCT:policy/petedio-dashboard-boundary"
if aws iam get-policy --policy-arn "$BND" >/dev/null 2>&1; then
  for v in $(aws iam list-policy-versions --policy-arn "$BND" --query 'Versions[?!IsDefaultVersion].VersionId' --output text); do aws iam delete-policy-version --policy-arn "$BND" --version-id "$v" >/dev/null; done
  aws iam create-policy-version --policy-arn "$BND" --policy-document "file://$T/boundary.json" --set-as-default >/dev/null || { echo "ABORT: boundary update failed."; exit 1; }
  echo "updated: boundary policy"
else
  aws iam create-policy --policy-name petedio-dashboard-boundary --policy-document "file://$T/boundary.json" >/dev/null || { echo "ABORT: boundary create failed."; exit 1; }
  echo "created: boundary policy"
fi

trust() { # $1 = the sub claim the role accepts
  cat <<JSON
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Federated":"$PROV"},
 "Action":"sts:AssumeRoleWithWebIdentity",
 "Condition":{"StringEquals":{"$OIDC:aud":"sts.amazonaws.com","$OIDC:sub":"$1"}}}]}
JSON
}
role() { # name, sub
  trust "$2" > "$T/trust.json"
  if aws iam get-role --role-name "$1" >/dev/null 2>&1; then
    aws iam update-assume-role-policy --role-name "$1" --policy-document "file://$T/trust.json" || return 1
    echo "updated: role $1"
  else
    aws iam create-role --role-name "$1" --max-session-duration 3600 --assume-role-policy-document "file://$T/trust.json" >/dev/null || return 1
    echo "created: role $1"
  fi
}
for r in dashboard portfolio; do
  role "petedio-ci-$r-plan"  "repo:$REPO:ref:refs/heads/main" || { echo "ABORT: $r plan role failed."; exit 1; }
  role "petedio-ci-$r-apply" "repo:$REPO:environment:lab-write" || { echo "ABORT: $r apply role failed."; exit 1; }
  aws iam attach-role-policy --role-name "petedio-ci-$r-plan" --policy-arn arn:aws:iam::aws:policy/ReadOnlyAccess || { echo "ABORT: attach failed."; exit 1; }
done

cat > "$T/apply.json" <<JSON
{"Version":"2012-10-17","Statement":[
 {"Sid":"Read","Effect":"Allow","Action":["iam:Get*","iam:List*","sts:GetCallerIdentity"],"Resource":"*"},
 {"Sid":"Services","Effect":"Allow","Action":["s3:*","cloudfront:*","lambda:*","apigateway:*","dynamodb:*","cognito-idp:*","logs:*","route53:*","acm:*"],"Resource":"*"},
 {"Sid":"IamNamedOnly","Effect":"Allow","Action":["iam:CreateUser","iam:CreateRole","iam:CreatePolicy","iam:PutRolePolicy","iam:PutUserPolicy","iam:AttachRolePolicy","iam:AttachUserPolicy","iam:PutUserPermissionsBoundary","iam:PutRolePermissionsBoundary","iam:TagUser","iam:TagRole","iam:TagPolicy","iam:UpdateAssumeRolePolicy","iam:CreatePolicyVersion"],
  "Resource":["arn:aws:iam::$ACCT:user/petedio-dash-*","arn:aws:iam::$ACCT:role/petedio-dash-*","arn:aws:iam::$ACCT:policy/petedio-dash-*"]},
 {"Sid":"BoundaryRequired","Effect":"Deny","Action":["iam:CreateUser","iam:CreateRole","iam:PutUserPermissionsBoundary","iam:PutRolePermissionsBoundary"],"Resource":"*","Condition":{"StringNotEquals":{"iam:PermissionsBoundary":"$BND"}}},
 {"Sid":"BoundaryStays","Effect":"Deny","Action":["iam:DeleteUserPermissionsBoundary","iam:DeleteRolePermissionsBoundary"],"Resource":"*"},
 {"Sid":"PassToLambda","Effect":"Allow","Action":"iam:PassRole","Resource":"arn:aws:iam::$ACCT:role/petedio-dash-*","Condition":{"StringEquals":{"iam:PassedToService":["lambda.amazonaws.com","apigateway.amazonaws.com"]}}},
 {"Sid":"NoDeletes","Effect":"Deny","Action":["iam:DeleteUser","iam:DeleteRole","iam:DeleteOpenIDConnectProvider","iam:DeletePolicy","dynamodb:DeleteTable","s3:DeleteBucket","route53:DeleteHostedZone"],"Resource":"*"}
]}
JSON
aws iam put-role-policy --role-name petedio-ci-dashboard-apply --policy-name apply --policy-document "file://$T/apply.json" || { echo "ABORT: dashboard apply policy failed."; exit 1; }

# Portfolio: the site's services only, no IAM writes, no deletes. An IAM change in this root
# needs the Mac.
cat > "$T/portfolio.json" <<JSON
{"Version":"2012-10-17","Statement":[
 {"Sid":"Read","Effect":"Allow","Action":["iam:Get*","iam:List*","sts:GetCallerIdentity"],"Resource":"*"},
 {"Sid":"Services","Effect":"Allow","Action":["s3:*","cloudfront:*","acm:*"],"Resource":"*"},
 {"Sid":"NoDeletes","Effect":"Deny","Action":["s3:DeleteBucket","cloudfront:DeleteDistribution","acm:DeleteCertificate"],"Resource":"*"}
]}
JSON
aws iam put-role-policy --role-name petedio-ci-portfolio-apply --policy-name apply --policy-document "file://$T/portfolio.json" || { echo "ABORT: portfolio apply policy failed."; exit 1; }
echo "done: provider, boundary, 4 roles, 2 apply policies. Tell the thread: bootstrap finished."
