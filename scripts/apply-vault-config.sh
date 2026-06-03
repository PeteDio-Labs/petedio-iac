#!/usr/bin/env bash
# apply-vault-config.sh — apply the environments/homelab/vault-config workspace with the
# review baked in as code. The vault-config workspace (KV mount, policies, AppRoles, the
# GitHub-OIDC JWT auth role) is operator-applied — CI never touches it — because it needs a
# privileged Vault token. This plans first and REFUSES to apply if the plan would destroy
# anything, so routine changes (e.g. a JWT bound_claims edit) apply safely and unattended.
#
#   Vault token: $VAULT_TOKEN, else macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM, else prompt
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"
VCDIR="$HOMELAB/vault-config"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }
[ -d "$VCDIR" ] || die "vault-config dir not found: $VCDIR"
cd "$VCDIR"

step "Credentials"
if [ -z "${VAULT_TOKEN:-}" ]; then
  VAULT_TOKEN="$(security find-generic-password -s "$VAULT_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null || true)"
fi
[ -n "${VAULT_TOKEN:-}" ] || { read -rsp "Vault token: " VAULT_TOKEN; echo; }
export VAULT_TOKEN
vault token lookup >/dev/null 2>&1 || die "Vault token invalid / Vault unreachable."
# vault-config state lives in the MinIO S3 backend
AWS_ACCESS_KEY_ID="$(vault kv get -field=access_key kv/iac/minio)"; export AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY="$(vault kv get -field=secret_key kv/iac/minio)"; export AWS_SECRET_ACCESS_KEY
[ -n "$AWS_ACCESS_KEY_ID" ] && [ -n "$AWS_SECRET_ACCESS_KEY" ] || die "could not read kv/iac/minio."

step "init + plan"
terraform init -reconfigure -input=false >/tmp/vc-init.log 2>&1 || { tail -15 /tmp/vc-init.log; die "terraform init failed."; }
terraform plan -input=false -no-color -out=tfplan 2>&1 | tee /tmp/vc-plan.txt

step "review (as code) — refuse to apply on any destroy"
if grep -qE '^No changes\.' /tmp/vc-plan.txt; then
  echo "No changes — nothing to apply."; exit 0
fi
PLAN_LINE="$(grep -E '^Plan: ' /tmp/vc-plan.txt | tail -1 || true)"
[ -n "$PLAN_LINE" ] || die "no 'Plan:' summary — inspect /tmp/vc-plan.txt."
DES="$(sed -E 's/.* ([0-9]+) to destroy.*/\1/' <<<"$PLAN_LINE")"
echo "  $PLAN_LINE"
[ "$DES" = "0" ] || die "plan would DESTROY $DES resource(s) — not applying. Inspect /tmp/vc-plan.txt."

step "apply (guard passed: 0 to destroy)"
terraform apply -input=false tfplan
echo "vault-config applied."
