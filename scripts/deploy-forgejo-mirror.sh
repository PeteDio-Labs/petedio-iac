#!/usr/bin/env bash
# deploy-forgejo-mirror.sh — read the read-only GitHub App from Vault and run
# configure-forgejo-mirror.yml against forgejo-249 (PET-756). Modeled on deploy-metrics.sh.
#
#   kv/services/forgejo-mirror -> app_id, installation_id, app_pem
#     Seeded by seed-forgejo-mirror-vault.sh.
#
#   AppRole creds: $SECRETS_DIR/ansible.{role_id,secret_id} (gitignored .secrets/)
#
# The values reach jq through its environment, never argv, because `ps` reads argv. The
# extra-vars file lives in a 0700 temp directory and is deleted on exit.
#
#   ./scripts/deploy-forgejo-mirror.sh [extra ansible-playbook args, such as --check --diff]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"
SECRETS="${SECRETS_DIR:-$REPO_ROOT/.secrets}"
ANSIBLE_DIR="$REPO_ROOT/ansible"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"

step() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die() { printf '\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }

for t in vault jq ansible-playbook; do command -v "$t" >/dev/null || die "$t not in PATH"; done
[ -f "$SECRETS/ansible.role_id" ] && [ -f "$SECRETS/ansible.secret_id" ] \
  || die "ansible AppRole creds not in $SECRETS."

step "Reading kv/services/forgejo-mirror (ansible AppRole)"
AN_TOKEN="$(vault write -field=token auth/approle/login \
  role_id=@"$SECRETS/ansible.role_id" secret_id=@"$SECRETS/ansible.secret_id" 2>/dev/null)" \
  || die "AppRole login failed for 'ansible'. Run ./scripts/pet-secrets doctor to see whether Vault is sealed."
RECORD="$(VAULT_TOKEN="$AN_TOKEN" vault kv get -format=json kv/services/forgejo-mirror 2>&1)" \
  || { unset AN_TOKEN; die "reading kv/services/forgejo-mirror failed. Run ./scripts/seed-forgejo-mirror-vault.sh first, or ./scripts/pet-secrets doctor."; }
unset AN_TOKEN

umask 077
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
jq -e '.data.data
    | select((.app_id // "") != "" and (.installation_id // "") != "" and ((.app_pem // "") | length) > 0)
    | {forgejo_mirror_app_id: .app_id, forgejo_mirror_installation_id: .installation_id,
       forgejo_mirror_app_pem: .app_pem}' <<<"$RECORD" >"$TMP/extra.json" \
  || die "kv/services/forgejo-mirror lacks app_id, installation_id or app_pem. Run ./scripts/seed-forgejo-mirror-vault.sh."
unset RECORD
echo "  app_id, installation_id and app_pem: present"

step "Running configure-forgejo-mirror.yml"
cd "$ANSIBLE_DIR"
ansible-playbook -i inventory/forgejo.yml playbooks/configure-forgejo-mirror.yml -e "@$TMP/extra.json" "$@"

step "Done"
cat <<'TXT'
  The play ran the first sync and failed if it examined fewer repos than GitHub reported.
  Read the summary:  ssh root@192.168.50.249 cat /var/lib/forgejo-mirror/status.json
  Add a login for yourself: docs/runbooks/forgejo-mirror.md, "Sign in".
TXT
