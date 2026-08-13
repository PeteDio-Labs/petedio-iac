#!/usr/bin/env bash
# deploy-plane.sh — resolve Plane's secrets from Vault and run configure-plane.yml
# against LXC 235.
#
# Operator run. Resolves under the ansible AppRole and passes as no_log extra-vars:
#   kv/db/plane        password    -> plane_db_password   (the database owner on 231)
#   kv/services/plane  secret_key  -> plane_secret_key    (Django SECRET_KEY)
#   kv/services/plane  access_key  -> plane_minio_access_key
#   kv/services/plane  secret_key_minio -> plane_minio_secret_key
#   kv/services/plane  live_secret_key  -> plane_live_secret_key  (LIVE_SERVER_SECRET_KEY)
#   kv/services/plane  mq_password      -> plane_mq_password      (bundled RabbitMQ)
#   AppRole creds: $SECRETS_DIR/ansible.{role_id,secret_id} (gitignored .secrets/)
#
# Manual-validation-first (standing convention, PET-266): this script IS the
# manual-deploy proof. Nothing gets wired to CD-on-merge until a run of this is green.
#
# ORDER MATTERS — this will fail loudly, and correctly, if you skip a step:
#   1. plane.tf applied (LXC 235 exists)
#   2. scripts/lxc-features-235.sh run (nesting=1,keyctl=1 — Docker won't start without)
#   3. `plane` database exists on 231 (databases.tf) and kv/db/plane is seeded
#   4. `plane` bucket exists on 245 (group_vars/minio_data.yml + deploy-minio-data.sh)
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
for t in vault ansible-playbook python3; do command -v "$t" >/dev/null || die "$t not in PATH"; done
[ -f "$SECRETS/ansible.role_id" ] && [ -f "$SECRETS/ansible.secret_id" ] \
  || die "ansible AppRole creds not in $SECRETS."

applogin(){ local rid sid; rid="$(cat "$SECRETS/$1.role_id")"; sid="$(cat "$SECRETS/$1.secret_id")"
  vault write -field=token auth/approle/login role_id="$rid" secret_id="$sid" 2>/dev/null \
    || die "AppRole login failed for '$1'."; }

step "Vault: login as the ansible AppRole"
AN_TOKEN="$(applogin ansible)"

step "Vault: resolve Plane's secrets"
DB_PW="$(VAULT_TOKEN="$AN_TOKEN" vault kv get -field=password kv/db/plane)" \
  || die "cannot read kv/db/plane field 'password' — has the database been seeded?"
SECRET_KEY="$(VAULT_TOKEN="$AN_TOKEN" vault kv get -field=secret_key kv/services/plane)" \
  || die "cannot read kv/services/plane field 'secret_key'."
MINIO_AK="$(VAULT_TOKEN="$AN_TOKEN" vault kv get -field=access_key kv/services/plane)" \
  || die "cannot read kv/services/plane field 'access_key'."
MINIO_SK="$(VAULT_TOKEN="$AN_TOKEN" vault kv get -field=secret_key_minio kv/services/plane)" \
  || die "cannot read kv/services/plane field 'secret_key_minio'."
LIVE_KEY="$(VAULT_TOKEN="$AN_TOKEN" vault kv get -field=live_secret_key kv/services/plane)" \
  || die "cannot read kv/services/plane field 'live_secret_key'."
MQ_PW="$(VAULT_TOKEN="$AN_TOKEN" vault kv get -field=mq_password kv/services/plane)" \
  || die "cannot read kv/services/plane field 'mq_password'."
echo "  resolved 6 secrets (values not printed)"

step "Preflight: is 235 up and does it have the container features?"
ssh -i ~/.ssh/id_ed25519_ansible -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 \
  root@192.168.50.235 true 2>/dev/null || die "235 not answering SSH — is plane.tf applied?"

step "Ansible: configure-plane.yml"
cd "$ANSIBLE_DIR"
ansible-playbook playbooks/configure-plane.yml \
  -e "plane_db_password=$DB_PW" \
  -e "plane_secret_key=$SECRET_KEY" \
  -e "plane_minio_access_key=$MINIO_AK" \
  -e "plane_minio_secret_key=$MINIO_SK" \
  -e "plane_live_secret_key=$LIVE_KEY" \
  -e "plane_mq_password=$MQ_PW" \
  "$@"

step "Done. Re-run this script — a converged host must report changed=0."
