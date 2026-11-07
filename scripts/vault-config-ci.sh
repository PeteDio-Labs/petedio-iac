#!/usr/bin/env bash
# vault-config-ci.sh plan|apply: the steps of .github/workflows/vault-config-apply.yml.
#
# plan  : terraform plan, then the guard. Writes `digest` and `changes` to $GITHUB_OUTPUT.
# apply : terraform plan again, the guard with EXPECT_DIGEST, then apply the saved plan and plan once
#         more, which must report no changes. Every failure exits non-zero.
set -euo pipefail
umask 077
# The OIDC token is already short-lived. The provider would otherwise mint a child token, which the policies do not allow.
export TERRAFORM_VAULT_SKIP_CHILD_TOKEN=true
trap 'rm -f /tmp/vc-init.log /tmp/vc-plan.txt /tmp/vc-plan.json /tmp/vc-digest /tmp/vc-guard.txt /tmp/vc-verify.txt "$PWD"/tfplan 2>/dev/null' EXIT
MODE="${1:-}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/environments/homelab/vault-config"
out="${GITHUB_OUTPUT:-/dev/null}"

terraform init -input=false -reconfigure >/tmp/vc-init.log 2>&1 || { tail -15 /tmp/vc-init.log; echo "ABORT: terraform init failed."; exit 1; }
rm -f tfplan
terraform plan -input=false -no-color -out=tfplan >/tmp/vc-plan.txt 2>&1 || { tail -30 /tmp/vc-plan.txt; echo "ABORT: terraform plan failed."; exit 1; }
terraform show -json tfplan >/tmp/vc-plan.json
grep -E '^(Plan:|No changes)' /tmp/vc-plan.txt || true

args=()
[ "$MODE" = "apply" ] && [ -n "${EXPECT_DIGEST:-}" ] && args=(--expect-digest "$EXPECT_DIGEST")
python3 "$ROOT/scripts/vault-config-guard.py" /tmp/vc-plan.json "${args[@]}" --digest-out /tmp/vc-digest | tee /tmp/vc-guard.txt
digest="$(cat /tmp/vc-digest)"
changes="$(sed -n 's/^guard: examined [0-9]* resource changes: \([0-9]*\) to apply.*/\1/p' /tmp/vc-guard.txt)"
[ -n "$changes" ] || { echo "ABORT: could not read the guard's summary."; exit 1; }
echo "digest=$digest" >>"$out"; echo "changes=$changes" >>"$out"

case "$MODE" in
  plan) echo "plan: $changes change(s) the gated apply could make. Approve the lab-write job to apply them." ;;
  apply)
    [ -n "${EXPECT_DIGEST:-}" ] || { echo "ABORT: no digest from the plan job."; exit 1; }
    [ "$changes" != "0" ] || { echo "apply: nothing to apply."; exit 0; }
    terraform apply -input=false tfplan
    rm -f tfplan
    # Verify: the same root must now plan clean.
    set +e; terraform plan -input=false -no-color -detailed-exitcode >/tmp/vc-verify.txt 2>&1; rc=$?; set -e
    [ "$rc" = "0" ] || { tail -20 /tmp/vc-verify.txt; echo "ABORT: plan after apply is not empty (exit $rc)."; exit 1; }
    echo "apply: $changes change(s) applied; plan after apply is empty." ;;
  *) echo "usage: $0 plan|apply" >&2; exit 2 ;;
esac
