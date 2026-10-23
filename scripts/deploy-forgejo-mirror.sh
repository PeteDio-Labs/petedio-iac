#!/usr/bin/env bash
# deploy-forgejo-mirror.sh — read the read-only GitHub App from Vault and run
# configure-forgejo-mirror.yml against forgejo-249 (PET-756). Modeled on deploy-metrics.sh.
#
#   kv/services/forgejo-mirror -> app_id, installation_id, app_pem
#     Seeded by seed-forgejo-mirror-vault.sh.
#
# Vault access, in this order:
#   $VAULT_TOKEN              a `vault-breakglass` shell on 247 (the token can read kv/data/*)
#   AppRole creds             $SECRETS_DIR/ansible.{role_id,secret_id} (gitignored .secrets/)
#
# SSH to the new LXC uses ~/.ssh/id_ed25519_ansible. Where that file is absent, as on 247 after
# PET-725, the script reads kv/iac/lxc-ssh field private_key with the same Vault token into the
# 0700 temp directory and passes it to ansible. That read needs the break-glass token.
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
if [ -n "${VAULT_TOKEN:-}" ]; then
  AN_TOKEN="$VAULT_TOKEN"
else
  [ -f "$SECRETS/ansible.role_id" ] && [ -f "$SECRETS/ansible.secret_id" ] \
    || die "No VAULT_TOKEN and no ansible AppRole creds in $SECRETS. On 247, run vault-breakglass first."
  AN_TOKEN="$(vault write -field=token auth/approle/login \
    role_id=@"$SECRETS/ansible.role_id" secret_id=@"$SECRETS/ansible.secret_id" 2>/dev/null)" \
    || die "AppRole login failed for 'ansible'. Run ./scripts/pet-secrets doctor to see whether Vault is sealed."
fi

step "Reading kv/services/forgejo-mirror"
RECORD="$(VAULT_TOKEN="$AN_TOKEN" vault kv get -format=json kv/services/forgejo-mirror 2>&1)" \
  || { unset AN_TOKEN; die "reading kv/services/forgejo-mirror failed. Seed it first (docs/runbooks/forgejo-mirror.md), or run ./scripts/pet-secrets doctor."; }

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

SSH_ARGS=()
if [ ! -f "$HOME/.ssh/id_ed25519_ansible" ]; then
  step "No ~/.ssh/id_ed25519_ansible: reading kv/iac/lxc-ssh"
  VAULT_TOKEN="$AN_TOKEN" vault kv get -field=private_key kv/iac/lxc-ssh >"$TMP/lxc-ssh.key" \
    || die "cannot read kv/iac/lxc-ssh with this token. Use a vault-breakglass shell."
  chmod 600 "$TMP/lxc-ssh.key"
  SSH_ARGS=(-e "ansible_ssh_private_key_file=$TMP/lxc-ssh.key")
fi
unset AN_TOKEN

step "Running configure-forgejo-mirror.yml"
cd "$ANSIBLE_DIR"
ansible-playbook -i inventory/forgejo.yml playbooks/configure-forgejo-mirror.yml -e "@$TMP/extra.json" "${SSH_ARGS[@]}" "$@"

step "Done"
cat <<'TXT'
  The play ran the first sync and failed if it examined fewer repos than GitHub reported.
  Read the summary:  ssh root@192.168.50.249 cat /var/lib/forgejo-mirror/status.json
  Add a login for yourself: docs/runbooks/forgejo-mirror.md, "Sign in".
TXT
