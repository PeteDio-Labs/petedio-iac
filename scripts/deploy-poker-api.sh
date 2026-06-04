#!/usr/bin/env bash
# deploy-poker-api.sh — resolve the Co-latro rollout secrets from Vault and run
# configure-poker-api.yml against LXC 230. (PET-44 driver)
#
# Follows the repo convention (reseed/import scripts): resolve secrets BEFORE the
# playbook and pass them as no_log extra-vars, rather than an in-playbook hashi_vault
# lookup. DATABASE_URL is read with the terraform-local AppRole (granted kv/poker/*);
# the ansible policy is deliberately NOT granted poker/* (docs/runbooks/vault-seed.md).
# Nexus + frontend-bucket MinIO creds come from kv/services/* (ansible-readable, but we
# read them here too so the playbook stays secret-free).
#
# Idempotent; no secrets printed. Run PET-43 (scripts/lxc-features-230.sh) FIRST.
#   AppRole creds: $SECRETS_DIR/terraform-local.{role_id,secret_id} (gitignored .secrets/)
#   Optional: -e backend_image_tag=<sha> passthrough via $IMAGE_TAG
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"
SECRETS="${SECRETS_DIR:-$REPO_ROOT/.secrets}"
ANSIBLE_DIR="$REPO_ROOT/ansible"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }
for t in vault ansible-playbook; do command -v "$t" >/dev/null || die "$t not in PATH"; done
[ -f "$SECRETS/terraform-local.role_id" ] || die "AppRole creds not in $SECRETS (see vault-seed.md)."

step "AppRole login (terraform-local — can read kv/poker/*)"
RID="$(cat "$SECRETS/terraform-local.role_id")"; SID="$(cat "$SECRETS/terraform-local.secret_id")"
VAULT_TOKEN="$(vault write -field=token auth/approle/login role_id="$RID" secret_id="$SID")"; export VAULT_TOKEN
vault token lookup >/dev/null 2>&1 || die "AppRole login failed."

step "Resolving secrets from Vault"
DB_URL="$(vault kv get -field=DATABASE_URL kv/poker/db)" || die "cannot read kv/poker/db."
NEXUS_U="$(vault kv get -field=username kv/services/nexus 2>/dev/null || echo admin)"
NEXUS_P="$(vault kv get -field=admin_password kv/services/nexus)" || die "cannot read kv/services/nexus."
MINIO_AK="$(vault kv get -field=access_key kv/services/minio-frontend)" \
  || die "cannot read kv/services/minio-frontend — run scripts/reseed-minio-frontend-vault.sh first."
MINIO_SK="$(vault kv get -field=secret_key kv/services/minio-frontend)" || die "cannot read minio-frontend secret_key."
[ -n "$DB_URL" ] && [ -n "$NEXUS_P" ] && [ -n "$MINIO_AK" ] && [ -n "$MINIO_SK" ] || die "a required secret was empty."

step "Running configure-poker-api.yml against poker-api (230)"
EXTRA_TAG=()
[ -n "${IMAGE_TAG:-}" ] && EXTRA_TAG=(-e "backend_image_tag=$IMAGE_TAG")

cd "$ANSIBLE_DIR"
# Pass secrets via a JSON extra-vars file on a private tmp path (never argv, never logged).
EVARS="$(mktemp)"; chmod 600 "$EVARS"; trap 'rm -f "$EVARS"' EXIT
cat > "$EVARS" <<JSON
{
  "colatro_database_url": $(printf '%s' "$DB_URL" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))'),
  "nexus_username": $(printf '%s' "$NEXUS_U" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))'),
  "nexus_password": $(printf '%s' "$NEXUS_P" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))'),
  "minio_frontend_access_key": $(printf '%s' "$MINIO_AK" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))'),
  "minio_frontend_secret_key": $(printf '%s' "$MINIO_SK" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))')
}
JSON

ansible-playbook playbooks/configure-poker-api.yml -e "@$EVARS" "${EXTRA_TAG[@]}"

step "Done — Co-latro rolled out to LXC 230."
echo "Smoke test: see docs/runbooks/poker-api-deploy.md."
