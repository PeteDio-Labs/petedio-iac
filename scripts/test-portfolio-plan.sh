#!/usr/bin/env bash
# test-portfolio-plan.sh — the plan user's policy must cover the refresh of every resource type
# in modules/portfolio-site (PET-884). A refresh that lacks one action fails the plan before it
# prints anything, so this test fails first. It also fails on a resource type it has no row for,
# so adding a resource to the module forces an edit here and in the policy.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
POLICY=scripts/aws-portfolio-plan-policy.json
jq -e . "$POLICY" >/dev/null || { echo "FAIL: $POLICY is not JSON"; exit 1; }

# resource type -> the read actions its provider refresh calls
declare -A NEED=(
  [aws_acm_certificate]="acm:DescribeCertificate acm:ListTagsForCertificate"
  [aws_acm_certificate_validation]="acm:DescribeCertificate"
  [aws_cloudfront_distribution]="cloudfront:GetDistribution cloudfront:ListTagsForResource"
  [aws_cloudfront_function]="cloudfront:DescribeFunction cloudfront:GetFunction"
  [aws_cloudfront_origin_access_control]="cloudfront:GetOriginAccessControl"
  [aws_cloudfront_response_headers_policy]="cloudfront:GetResponseHeadersPolicy"
  [aws_iam_openid_connect_provider]="iam:GetOpenIDConnectProvider"
  [aws_iam_role]="iam:GetRole iam:ListRolePolicies iam:ListAttachedRolePolicies"
  [aws_iam_role_policy]="iam:GetRolePolicy"
  [aws_iam_user]="iam:GetUser iam:ListAccessKeys"
  [aws_iam_user_policy]="iam:GetUserPolicy"
  [aws_s3_bucket]="s3:ListBucket s3:GetBucketPolicy s3:GetBucketTagging s3:GetBucketVersioning s3:GetAccelerateConfiguration s3:GetLifecycleConfiguration s3:GetReplicationConfiguration s3:GetEncryptionConfiguration"
  [aws_s3_bucket_ownership_controls]="s3:GetBucketOwnershipControls"
  [aws_s3_bucket_policy]="s3:GetBucketPolicy"
  [aws_s3_bucket_public_access_block]="s3:GetBucketPublicAccessBlock"
  [aws_s3_bucket_server_side_encryption_configuration]="s3:GetEncryptionConfiguration"
)

covered() { # does an allow pattern in the policy match this action?
  jq -e --arg a "$1" '[.Statement[] | select(.Effect=="Allow") | .Action[]]
    | any(. as $p | ($p == $a) or ($p | endswith("*") and ($a | startswith($p[:-1]))))' "$POLICY" >/dev/null
}

fail=0; seen=0
for t in $(grep -rhoE '^resource "aws_[a-z0-9_]+"' modules/portfolio-site/*.tf | sed -E 's/resource "(.*)"/\1/' | sort -u); do
  seen=$((seen+1))
  if [ -z "${NEED[$t]:-}" ]; then echo "FAIL: no row for $t in this test. Add its refresh actions here and to $POLICY."; fail=1; continue; fi
  for a in ${NEED[$t]}; do
    covered "$a" || { echo "FAIL: $t needs $a, and the policy does not allow it"; fail=1; }
  done
done
[ "$seen" -gt 0 ] || { echo "FAIL: found 0 resource types in modules/portfolio-site, so nothing was checked"; exit 1; }
[ "$fail" -eq 0 ] || exit 1
echo "ok: $seen resource types in modules/portfolio-site, every refresh action is allowed"
