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
#   bash scripts/portfolio-deploy-key.sh --profile dreamitshipit --reset  # delete every key, make a new one
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
    --reset) mode="reset"; shift ;;
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

# Read back the environment's secret names. Fails unless the read succeeds and both names are there.
check_secrets() {
  local names
  names=$(gh secret list --env "$env_name" --repo "$repo" --json name --jq '.[].name') || { echo "Could not read the environment secrets on $repo/$env_name." >&2; return 1; }
  echo "environment secrets on $repo/$env_name: $(printf '%s' "$names" | sort | tr '\n' ' ')"
  for want in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
    printf '%s\n' "$names" | grep -qx "$want" || { echo "Missing environment secret $want on $repo/$env_name." >&2; return 1; }
  done
}

if [ "$mode" = "check" ]; then
  check_secrets || exit 1
  [ "$old_count" -eq 1 ] || { echo "Expected exactly one key, found $old_count." >&2; exit 1; }
  echo "OK: one key and both secrets present (the key value is not readable, so this does not prove they match)."
  exit 0
fi

if [ "$mode" = "create" ] && [ "$old_count" -gt 0 ]; then
  echo "The user already has a key and AWS cannot show it again. Re-run with --rotate to replace it, or --reset to discard it." >&2
  exit 1
fi
if [ "$mode" = "reset" ]; then
  # Explicit credential reset: the deploy has no working key between the deletes and the new secrets.
  echo "--reset: deleting all $old_count key(s), then creating a fresh one"
  for k in $old_keys; do
    awsx iam delete-access-key --user-name "$user" --access-key-id "$k" || { echo "Could not delete $k." >&2; exit 1; }
    echo "deleted key $k"
  done
  old_keys=""
elif [ "$old_count" -ge 2 ]; then
  # Two keys can mean a rotation stopped after the new key was stored, so one of them may still be
  # the working one. Do not guess which: --rotate never deletes a key it has not proved replaced.
  echo "The user has $old_count keys (an earlier rotation stopped part way). --rotate will not choose one to delete." >&2
  echo "Run --check, and a deploy, to see whether the stored secrets still work. To discard both keys and start over (the deploy has no key until the script finishes), run with --reset." >&2
  exit 1
fi

# The environment holds the secrets and limits deployment to main.
echo "creating environment $env_name on $repo, main only"
gh api -X PUT "repos/$repo/environments/$env_name" \
  -F 'deployment_branch_policy[protected_branches]=false' \
  -F 'deployment_branch_policy[custom_branch_policies]=true' --silent || { echo "Could not create the environment." >&2; exit 1; }
# Require EXACTLY one policy: the branch `main`. Remove any other, then read the set back.
pol="repos/$repo/environments/$env_name/deployment-branch-policies"
policies=$(gh api "$pol" --jq '.branch_policies[] | [.id, .name, .type] | @tsv') || { echo "Could not read the deployment branch policies." >&2; exit 1; }
have_main=0
while IFS=$'\t' read -r pid pname ptype; do
  [ -n "$pid" ] || continue
  if [ "$pname" = "main" ] && [ "$ptype" = "branch" ]; then
    have_main=1
  else
    echo "removing deployment policy '$pname' ($ptype) from $env_name"
    gh api -X DELETE "$pol/$pid" --silent || { echo "Could not remove policy '$pname'." >&2; exit 1; }
  fi
done <<<"$policies"
if [ "$have_main" -eq 0 ]; then
  gh api -X POST "$pol" -f name=main -f type=branch --silent || { echo "Could not add the main branch policy." >&2; exit 1; }
fi
final_policies=$(gh api "$pol" --jq '[.branch_policies[] | "\(.name):\(.type)"] | join(",")') || { echo "Could not read the policies back." >&2; exit 1; }
[ "$final_policies" = "main:branch" ] || { echo "Environment $env_name allows '$final_policies', not only main:branch. No key was created." >&2; exit 1; }
echo "environment $env_name deploys only from: $final_policies"

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
  echo "FAILED while storing the key. GitHub may hold a mismatched pair, and the new secret is gone." >&2
  echo "Check whether a deploy still works. If not, run with --reset, which deletes every key and makes a fresh one." >&2
  exit 1
fi

for old in $old_keys; do
  awsx iam delete-access-key --user-name "$user" --access-key-id "$old" || { echo "Could not delete old key $old." >&2; exit 1; }
  echo "deleted old key $old"
done

check_secrets || exit 1
final=$(awsx iam list-access-keys --user-name "$user" --query 'AccessKeyMetadata[].AccessKeyId' --output text | wc -w | tr -d ' ')
[ "$final" -eq 1 ] || { echo "Expected one key, found $final." >&2; exit 1; }
echo "OK: $user has one key ($key_id), stored as environment secrets on $repo/$env_name."
