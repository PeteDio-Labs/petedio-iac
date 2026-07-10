#!/usr/bin/env bash
# deploy-palworld-panel.sh — resolve the panel's secrets from Vault and run
# configure-palworld-panel.yml against LXC 235. (PET-266 driver; mirrors deploy-poker-api.sh)
#
# Operator run (from the Mac). NOT applied on merge: the shared ansible-stack.yml apply can
# only mint the LXC key + Nexus creds, not the Palworld AdminPassword or the panel SSH key.
# Resolves everything under the ansible policy and passes it as no_log extra-vars:
#   kv/services/nexus          -> nexus_username / nexus_password       (docker login)
#   kv/services/palworld-panel -> admin_password / panel_ssh_private_key
#
# PREREQS: run scripts/lxc-features-235.sh FIRST (nesting for Docker), and publish the panel
# images to Nexus (the petedio-palworld-panel CI on merge to main).
#   AppRole creds: $SECRETS_DIR/ansible.{role_id,secret_id} (gitignored .secrets/)
#   Optional: -e palworld_panel_image_tag=<sha> via $IMAGE_TAG
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
  || die "ansible AppRole creds not in $SECRETS (see docs/runbooks/vault-seed.md)."

applogin(){ # $1=role -> token
  local rid sid
  rid="$(cat "$SECRETS/$1.role_id")"; sid="$(cat "$SECRETS/$1.secret_id")"
  vault write -field=token auth/approle/login role_id="$rid" secret_id="$sid" 2>/dev/null \
    || die "AppRole login failed for '$1'."
}

step "Resolving kv/services/{nexus,palworld-panel} (ansible AppRole)"
AN_TOKEN="$(applogin ansible)"
NEXUS_U="$(VAULT_TOKEN="$AN_TOKEN" vault kv get -field=username kv/services/nexus 2>/dev/null || echo admin)"
NEXUS_P="$(VAULT_TOKEN="$AN_TOKEN" vault kv get -field=admin_password kv/services/nexus)" || die "cannot read kv/services/nexus."
ADMIN_PW="$(VAULT_TOKEN="$AN_TOKEN" vault kv get -field=admin_password kv/services/palworld-panel)" \
  || die "cannot read kv/services/palworld-panel admin_password — seed it first."
SSH_KEY="$(VAULT_TOKEN="$AN_TOKEN" vault kv get -field=panel_ssh_private_key kv/services/palworld-panel)" \
  || die "cannot read kv/services/palworld-panel panel_ssh_private_key — seed it first."
[ -n "$NEXUS_P" ] && [ -n "$ADMIN_PW" ] && [ -n "$SSH_KEY" ] || die "a required secret was empty."

step "Running configure-palworld-panel.yml against palworld-panel-235"
EXTRA_TAG=()
[ -n "${IMAGE_TAG:-}" ] && EXTRA_TAG=(-e "palworld_panel_image_tag=$IMAGE_TAG")

cd "$ANSIBLE_DIR"
EVARS="$(mktemp)"; chmod 600 "$EVARS"; trap 'rm -f "$EVARS"' EXIT
cat > "$EVARS" <<JSON
{
  "nexus_username": $(printf '%s' "$NEXUS_U" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))'),
  "nexus_password": $(printf '%s' "$NEXUS_P" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))'),
  "palworld_admin_password": $(printf '%s' "$ADMIN_PW" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))'),
  "panel_ssh_private_key": $(printf '%s' "$SSH_KEY" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))')
}
JSON

ansible-playbook playbooks/configure-palworld-panel.yml -e "@$EVARS" "${EXTRA_TAG[@]}"

step "Done — control panel rolled out to LXC 235 (palworld.pdlab.dev)."
