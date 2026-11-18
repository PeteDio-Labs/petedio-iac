#!/usr/bin/env bash
# Plan or apply environments/dashboard for dashboard-apply.yml. Run from that directory.
#   plan   Plans, prints addresses and counts (never attribute values), and writes the plan
#          digest and the change count to $GITHUB_OUTPUT.
#   apply  Plans again, refuses unless its digest equals $EXPECT_DIGEST, applies the saved plan,
#          then reads the outputs back.
# Needs: MINIO_KEY, MINIO_SECRET, ROLE, ATTACH, and the GitHub OIDC request variables.
# Every failure exits non-zero, and every success line says what was examined.
set -euo pipefail
umask 077
MODE="${1:?plan or apply}"
: "${AWS_ACCOUNT:?}" "${BOUNDARY_ARN:?}" "${ROLE:?}"
for v in MINIO_KEY MINIO_SECRET ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_ID_TOKEN_REQUEST_TOKEN; do
  [ -n "${!v:-}" ] || { echo "ABORT: $v is empty."; exit 1; }
done
T="$RUNNER_TEMP/dashboard-$MODE"
rm -rf "$T"; mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

# The S3 backend reads AWS_ACCESS_KEY_ID for MinIO, so the AWS role comes from a named profile.
printf 'access_key = "%s"\nsecret_key = "%s"\n' "$MINIO_KEY" "$MINIO_SECRET" > "$T/backend.hcl"
curl -sS --fail -m 20 -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=sts.amazonaws.com" | jq -r .value > "$T/oidc-token"
[ -s "$T/oidc-token" ] && [ "$(cat "$T/oidc-token")" != null ] || { echo "ABORT: GitHub gave no OIDC token."; exit 1; }
cat > "$T/aws-config" <<CFG
[profile dash]
role_arn = arn:aws:iam::${AWS_ACCOUNT}:role/${ROLE}
web_identity_token_file = $T/oidc-token
role_session_name = dashboard-${MODE}-${GITHUB_RUN_ID:-local}
region = us-east-2
CFG
export AWS_CONFIG_FILE="$T/aws-config" AWS_SHARED_CREDENTIALS_FILE=/dev/null
export TF_DATA_DIR="$T/tfdata"
export TF_PLUGIN_CACHE_DIR="${RUNNER_TOOL_CACHE:-$HOME/.cache}/tf-plugin-cache"
mkdir -p "$TF_PLUGIN_CACHE_DIR"
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE

scrub() { sed -E 's/(key|secret|token)[^ ]*/[redacted]/Ig'; }
VARS=(-var aws_profile=dash -var "attach_domain=${ATTACH:-false}" -var "permissions_boundary_arn=$BOUNDARY_ARN")
echo "dashboard-$MODE: pet=${PET:-none} sha=$GITHUB_SHA role=$ROLE attach_domain=${ATTACH:-false}"

terraform init -input=false -backend-config="$T/backend.hcl" >"$T/init.log" 2>&1 \
  || { scrub < "$T/init.log" | tail -n 20; echo "ABORT: terraform init failed."; exit 1; }
set +e
terraform plan -input=false -lock=false -detailed-exitcode "${VARS[@]}" -out="$T/plan" >"$T/plan.log" 2>&1
rc=$?
set -e
if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then
  scrub < "$T/plan.log" | tail -n 25
  echo "ABORT: terraform plan failed (exit $rc). Nothing was examined."
  exit 1
fi
terraform show -json "$T/plan" > "$T/plan.json"
jq -r '(.resource_changes // [])[] | select(.change.actions != ["no-op"] and .change.actions != ["read"]) | "\(.change.actions | join("+")) \(.address | gsub("\\[[^]]*\\]"; "[]"))"' "$T/plan.json" | sort > "$T/changes.txt"
head -n 80 "$T/changes.txt"
total="$(jq '[(.resource_changes // [])[]] | length' "$T/plan.json")"
[ "$total" -gt 0 ] || { echo "ABORT: the plan lists 0 resources, so it examined nothing."; exit 1; }
changes="$(wc -l < "$T/changes.txt" | tr -d ' ')"
del="$(grep -c 'delete' "$T/changes.txt" || true)"
digest="$(sha256sum "$T/changes.txt" | cut -c1-16)"
echo "dashboard plan: $total resource(s) examined, $changes with a change, $del with a delete, digest $digest (terraform exit $rc)"
if [ "$MODE" = plan ]; then
  { echo "digest=$digest"; echo "changes=$changes"; } >> "$GITHUB_OUTPUT"
  exit 0
fi

: "${EXPECT_DIGEST:?}"
[ "$digest" = "$EXPECT_DIGEST" ] || { echo "ABORT: this plan's digest $digest differs from the plan job's $EXPECT_DIGEST. Run the workflow again."; exit 1; }
[ "$del" -eq 0 ] || { echo "ABORT: the plan deletes $del resource(s). This workflow does not apply a delete."; exit 1; }
terraform apply -input=false "$T/plan" >"$T/apply.log" 2>&1 \
  || { scrub < "$T/apply.log" | tail -n 40; echo "ABORT: terraform apply failed."; exit 1; }
scrub < "$T/apply.log" | tail -n 3
# Read back what exists now. A green apply that created nothing must not look healthy.
terraform output -json > "$T/out.json"
n="$(jq 'keys | length' "$T/out.json")"
[ "$n" -gt 0 ] || { echo "ABORT: the apply finished but the root has 0 outputs."; exit 1; }
echo "dashboard apply: read back $n output(s):"
jq -r 'to_entries[] | select(.value.sensitive | not) | "\(.key) = \(.value.value | tostring | .[0:120])"' "$T/out.json"
