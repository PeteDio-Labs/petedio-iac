#!/usr/bin/env bash
# deploy-backup-store.sh — run configure-backup-store.yml with the Kuma push tokens
# that the nodes' backup-health checks need (PET-529).
#
# The playbook runs without this wrapper. It then installs the check with no push URL,
# and each node's check fails its push step until a run through here supplies one.
#
# CREDENTIAL FLOW
#   kv/services/backup-health  pve02 / pve03, minted by scripts/seed-backup-health-vault.sh.
#   READ here under the ansible AppRole. Passed to Ansible in a 0600 file with -e @file,
#   never as -e key=value, because argv shows in `ps`. The file is removed on exit.
#
#   ./scripts/deploy-backup-store.sh                    # both plays
#   ./scripts/deploy-backup-store.sh --limit pve02      # extra args reach ansible-playbook
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
for t in vault ansible-playbook python3; do
  command -v "$t" >/dev/null || die "$t not in PATH"
done
[ -f "$SECRETS/ansible.role_id" ] && [ -f "$SECRETS/ansible.secret_id" ] \
  || die "ansible AppRole creds not in $SECRETS."

step "Vault: log in as the ansible AppRole"
RID="$(cat "$SECRETS/ansible.role_id")"; SID="$(cat "$SECRETS/ansible.secret_id")"
AN_TOKEN="$(vault write -field=token auth/approle/login \
  role_id="$RID" secret_id="$SID" 2>/dev/null)" || die "AppRole login failed."

step "Vault: read the push tokens"
VARS="$(mktemp)"
chmod 600 "$VARS"
trap 'rm -f "$VARS"' EXIT
VAULT_TOKEN="$AN_TOKEN" vault kv get -format=json kv/services/backup-health 2>/dev/null \
  | python3 -c '
import json, sys
tokens = json.load(sys.stdin)["data"]["data"]
json.dump({"backup_store_health_push_tokens": tokens}, open(sys.argv[1], "w"))
print("  tokens for: " + ", ".join(sorted(tokens)))
' "$VARS" \
  || die "cannot read kv/services/backup-health. Run scripts/seed-backup-health-vault.sh first."

step "Ansible: configure-backup-store.yml"
cd "$ANSIBLE_DIR"
ansible-playbook playbooks/configure-backup-store.yml -e "@$VARS" "$@"
