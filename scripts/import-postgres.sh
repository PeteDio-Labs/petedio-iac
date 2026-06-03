#!/usr/bin/env bash
# import-postgres.sh — one-time adoption: import a pre-existing `poker` Postgres role +
# database into Terraform state so cyrilgdn manages them, instead of trying to CREATE
# objects that already exist (which errors). Run this once before the first
# postgres_ready=true apply. Idempotent — skips resources already in state.
#
# Auth: the read-only `terraform-local` AppRole in <repo>/.secrets/ (no root token needed).
# Writes only to Terraform state (the import). Does NOT apply — the grant + any password
# reconcile happen on your normal `terraform apply` / apply-on-merge.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"
SECRETS="${SECRETS_DIR:-$REPO_ROOT/.secrets}"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }
for t in vault terraform; do command -v "$t" >/dev/null || die "$t not in PATH"; done
[ -f "$SECRETS/terraform-local.role_id" ] || die "AppRole creds not found in $SECRETS (provision them first)."

step "AppRole login (terraform-local — read-only KV, no root token)"
RID="$(cat "$SECRETS/terraform-local.role_id")"; SID="$(cat "$SECRETS/terraform-local.secret_id")"
VAULT_TOKEN="$(vault write -field=token auth/approle/login role_id="$RID" secret_id="$SID")"; export VAULT_TOKEN
vault token lookup >/dev/null 2>&1 || die "AppRole login failed."

step "Creds from Vault (state backend + required root vars)"
AWS_ACCESS_KEY_ID="$(vault kv get -field=access_key kv/iac/minio)"; export AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY="$(vault kv get -field=secret_key kv/iac/minio)"; export AWS_SECRET_ACCESS_KEY
# `terraform import` evaluates the WHOLE root module, so these required, no-default root
# vars must be set even though we only touch module.poker_db.
TF_VAR_proxmox_api_token="$(vault kv get -field=api_token kv/iac/proxmox)"; export TF_VAR_proxmox_api_token
TF_VAR_ssh_public_key="$(vault kv get -field=public_key kv/iac/lxc-ssh)"; export TF_VAR_ssh_public_key
[ -n "$AWS_ACCESS_KEY_ID" ] && [ -n "$TF_VAR_proxmox_api_token" ] && [ -n "$TF_VAR_ssh_public_key" ] \
  || die "could not read required secrets from kv/iac/*."

cd "$HOMELAB"
step "terraform init"
terraform init -reconfigure -input=false >/tmp/imp-init.log 2>&1 || { tail -15 /tmp/imp-init.log; die "init failed."; }

step "import the live poker role + database (idempotent; grant is not importable → left for apply)"
imp(){ # $1=address  $2=id
  if terraform state list 2>/dev/null | grep -qFx "$1"; then echo "  already in state: $1"
  else echo "  importing $1  <-  $2"; terraform import -input=false "$1" "$2"; fi
}
imp 'module.poker_db[0].postgresql_role.owner'    poker
imp 'module.poker_db[0].postgresql_database.this' poker

step "plan — must be 0 to destroy"
terraform plan -input=false -no-color 2>&1 | tee /tmp/imp-plan.txt >/dev/null
grep -E '^(  # |Plan:|No changes)' /tmp/imp-plan.txt | sed 's/^/  /' || true
if ! grep -qE '^No changes' /tmp/imp-plan.txt; then
  PLAN_LINE="$(grep -E '^Plan: ' /tmp/imp-plan.txt | tail -1 || true)"
  [ -n "$PLAN_LINE" ] || die "could not parse a Plan: summary — inspect /tmp/imp-plan.txt."
  DES="$(sed -E 's/.* ([0-9]+) to destroy.*/\1/' <<<"$PLAN_LINE")"
  [ "$DES" = "0" ] || die "plan shows $DES to DESTROY — STOP. Inspect /tmp/imp-plan.txt."
  grep -qE 'must be replaced|will be destroyed' /tmp/imp-plan.txt && die "plan would replace/destroy a resource — STOP."
fi

step "Done — role + database imported, plan is destroy-free"
echo "The remaining grant (and any password reconcile) applies on your next terraform apply."
