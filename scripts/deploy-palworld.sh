#!/usr/bin/env bash
# deploy-palworld.sh — run configure-palworld.yml against LXC 234 WITH the secrets that
# enable the control-panel integration (PET-266): the REST AdminPassword + the panel's SSH
# public key (the start-hook). Resolves them from Vault and passes them as no_log extra-vars,
# the repo convention (mirrors deploy-poker-api.sh).
#
# WHY A SCRIPT (not the ansible-palworld.yml apply-on-merge): that CI apply passes NO secrets,
# so it leaves REST off and the start-hook uninstalled (the .ini is byte-identical → no restart).
# Enabling REST is a deliberate, operator-timed action because it RESTARTS the live server once.
#
#   Vault:  kv/services/palworld-panel  →  admin_password, panel_ssh_public_key  (ansible policy)
#   AppRole creds: $SECRETS_DIR/ansible.{role_id,secret_id} (gitignored .secrets/)
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

step "Resolving kv/services/palworld-panel (ansible AppRole)"
AN_TOKEN="$(applogin ansible)"
ADMIN_PW="$(VAULT_TOKEN="$AN_TOKEN" vault kv get -field=admin_password kv/services/palworld-panel)" \
  || die "cannot read kv/services/palworld-panel admin_password — seed it first."
PANEL_PUBKEY="$(VAULT_TOKEN="$AN_TOKEN" vault kv get -field=panel_ssh_public_key kv/services/palworld-panel)" \
  || die "cannot read kv/services/palworld-panel panel_ssh_public_key — seed it first."
[ -n "$ADMIN_PW" ] && [ -n "$PANEL_PUBKEY" ] || die "a required secret was empty."

step "Applying configure-palworld.yml to 234 (enables REST + start-hook; restarts once)"
cd "$ANSIBLE_DIR"
EVARS="$(mktemp)"; chmod 600 "$EVARS"; trap 'rm -f "$EVARS"' EXIT
cat > "$EVARS" <<JSON
{
  "palworld_admin_password": $(printf '%s' "$ADMIN_PW" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))'),
  "palworld_panel_ssh_pubkey": $(printf '%s' "$PANEL_PUBKEY" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))')
}
JSON

ansible-playbook playbooks/configure-palworld.yml -e "@$EVARS"

step "Done — REST API enabled on 234 (8212/tcp, panel-only) + start-hook installed."
echo "Verify: ssh into 234 and 'curl -su admin:<pw> http://127.0.0.1:8212/v1/api/info'"
