#!/usr/bin/env bash
# Create (or rotate) the portfolio deploy access key and place it in GitHub (PET-816).
#
# Why a key: the AWS account's service control policy denies the GitHub OIDC provider, so
# the deploy workflow cannot assume a role by token. Terraform makes a deploy-only IAM user
# (environments/portfolio, deploy_auth = "user") and never the key, so no secret reaches state.
#
# Run it as Pedro, with `aws login` done for the account and `gh` signed in with admin rights
# on the repo. The file has no executable bit, so call it with bash:
#   bash scripts/portfolio-deploy-key.sh --profile dreamitshipit          # first key
#   bash scripts/portfolio-deploy-key.sh --profile dreamitshipit --rotate # replace the key
#   bash scripts/portfolio-deploy-key.sh --profile dreamitshipit --check  # read only
# Add --vault to also write kv/services/portfolio-deploy (needs `vault login`).
#
# The key goes from `aws iam create-access-key` straight into `gh secret set` as environment
# secrets on the repo's `production` environment, which only `main` may deploy to. The script
# never prints it, never writes it to disk and never puts it in a command line.
#
# FAILS CLOSED. The new key must authenticate as the deploy user before it is stored anywhere.
# It exits non-zero unless the read-back shows the user with exactly one key and both secrets
# present on the environment.
# It prints what it examined at each step.
set -uo pipefail
set +x

repo="PeteDio-Labs/pdlabs-portfolio"
user="petedio-portfolio-deploy"
env_name="production"
profile=""
mode="create"
use_vault=0

while [ $# -gt 0 ]; do
  case "$1" in
    --profile) profile="${2:-}"; shift 2 ;;
    --rotate) mode="rotate"; shift ;;
    --check) mode="check"; shift ;;
    --vault) use_vault=1; shift ;;
    --user) user="${2:-}"; shift 2 ;;
    --repo) repo="${2:-}"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$profile" ] || { echo "--profile is required (the AWS CLI profile for account 847547470418)." >&2; exit 2; }

for c in aws gh python3; do command -v "$c" >/dev/null || { echo "$c is not installed." >&2; exit 1; }; done
gh auth status >/dev/null 2>&1 || { echo "gh is not signed in." >&2; exit 1; }
[ "$use_vault" -eq 0 ] || command -v vault >/dev/null || { echo "vault is not installed." >&2; exit 1; }

awsx() { aws --profile "$profile" "$@"; }

account=$(awsx sts get-caller-identity --query Account --output text 2>/dev/null) || { echo "aws profile '$profile' is not signed in." >&2; exit 1; }
[ "$account" = "847547470418" ] || { echo "Profile '$profile' is account '$account', not 847547470418. Stopping." >&2; exit 1; }
echo "account: $account"

awsx iam get-user --user-name "$user" >/dev/null 2>&1 || { echo "IAM user '$user' does not exist. Apply environments/portfolio first." >&2; exit 1; }
old_keys=$(awsx iam list-access-keys --user-name "$user" --query 'AccessKeyMetadata[].AccessKeyId' --output text) || exit 1
old_count=$(printf '%s\n' "$old_keys" | wc -w | tr -d ' ')
echo "user $user has $old_count access key(s)"

report_secrets() {
  gh secret list --env "$env_name" --repo "$repo" --json name --jq '.[].name' 2>/dev/null | sort | tr '\n' ' '
}

if [ "$mode" = "check" ]; then
  echo "environment secrets on $repo/$env_name: $(report_secrets)"
  [ "$old_count" -eq 1 ] || { echo "Expected exactly one key." >&2; exit 1; }
  exit 0
fi

if [ "$mode" = "create" ] && [ "$old_count" -gt 0 ]; then
  echo "The user already has a key and AWS cannot show it again. Re-run with --rotate to replace it." >&2
  exit 1
fi
[ "$old_count" -lt 2 ] || { echo "The user has 2 keys (the AWS maximum). Delete one by hand, then re-run." >&2; exit 1; }

# The environment holds the secrets and limits deployment to main.
echo "creating environment $env_name on $repo, main only"
gh api -X PUT "repos/$repo/environments/$env_name" \
  -F 'deployment_branch_policy[protected_branches]=false' \
  -F 'deployment_branch_policy[custom_branch_policies]=true' --silent || { echo "Could not create the environment." >&2; exit 1; }
if ! gh api "repos/$repo/environments/$env_name/deployment-branch-policies" --jq '.branch_policies[].name' | grep -qx main; then
  gh api -X POST "repos/$repo/environments/$env_name/deployment-branch-policies" -f name=main -f type=branch --silent \
    || { echo "Could not restrict the environment to main." >&2; exit 1; }
fi

new=$(awsx iam create-access-key --user-name "$user" --output json) || { echo "create-access-key failed (the account's SCP may deny it)." >&2; exit 1; }
key_id=$(printf '%s' "$new" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["AccessKeyId"])') || exit 1
secret=$(printf '%s' "$new" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["SecretAccessKey"])') || exit 1
unset new
echo "created key $key_id"

# Prove the new key works as the deploy user BEFORE it replaces anything. A key that fails here
# was never stored, so the old secrets (if any) keep working.
who=""
for _ in 1 2 3 4 5 6; do
  who=$(AWS_ACCESS_KEY_ID="$key_id" AWS_SECRET_ACCESS_KEY="$secret" aws sts get-caller-identity --query Arn --output text 2>/dev/null) && break
  sleep 5   # a new key can take a few seconds to propagate
done
case "$who" in
  *":user/$user") echo "new key authenticates as: $who" ;;
  *)
    echo "New key did not authenticate as $user (got '${who:-nothing}'). Nothing was stored; deleting it." >&2
    awsx iam delete-access-key --user-name "$user" --access-key-id "$key_id" >&2
    exit 1
    ;;
esac

fail=0
printf '%s' "$key_id" | gh secret set AWS_ACCESS_KEY_ID --env "$env_name" --repo "$repo" || fail=1
printf '%s' "$secret" | gh secret set AWS_SECRET_ACCESS_KEY --env "$env_name" --repo "$repo" || fail=1

if [ "$use_vault" -eq 1 ] && [ "$fail" -eq 0 ]; then
  # printf, not a here-string: a here-string appends a newline to the secret.
  printf '%s' "$secret" \
    | python3 -c 'import json,sys; print(json.dumps({"access_key_id": sys.argv[1], "secret_access_key": sys.stdin.read()}))' "$key_id" \
    | vault kv put kv/services/portfolio-deploy - >/dev/null || fail=1
fi
unset secret

if [ "$fail" -ne 0 ]; then
  echo "FAILED while storing the key. The old key (if any) is not deleted, but the GitHub secrets may now hold the new one." >&2
  echo "New key $key_id is left in place. Re-run with --rotate to replace both, or delete it with:" >&2
  echo "  aws --profile $profile iam delete-access-key --user-name $user --access-key-id $key_id" >&2
  exit 1
fi

for old in $old_keys; do
  awsx iam delete-access-key --user-name "$user" --access-key-id "$old" || { echo "Could not delete old key $old." >&2; exit 1; }
  echo "deleted old key $old"
done

echo "environment secrets on $repo/$env_name: $(report_secrets)"
final=$(awsx iam list-access-keys --user-name "$user" --query 'AccessKeyMetadata[].AccessKeyId' --output text | wc -w | tr -d ' ')
[ "$final" -eq 1 ] || { echo "Expected one key, found $final." >&2; exit 1; }
echo "OK: $user has one key ($key_id), stored as environment secrets on $repo/$env_name."
