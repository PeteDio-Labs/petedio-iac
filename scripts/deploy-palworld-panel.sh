#!/usr/bin/env bash
# deploy-palworld-panel.sh — resolve the panel's secrets from Vault and run
# configure-palworld-panel.yml, which deploys the control panel natively on LXC 234. (PET-266)
#
# Operator run (from a controller with the petedio-palworld-panel checkout at $PANEL_SRC).
# Resolves under the ansible policy and passes as no_log extra-vars:
#   kv/services/palworld-panel -> admin_password (REST auth) + panel_ssh_private_key (start-hook)
#   AppRole creds: $SECRETS_DIR/ansible.{role_id,secret_id} (gitignored .secrets/)
#   PANEL_SRC (optional): path to the petedio-palworld-panel checkout (default ~/petedio/palworld-panel)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"
SECRETS="${SECRETS_DIR:-$REPO_ROOT/.secrets}"
ANSIBLE_DIR="$REPO_ROOT/ansible"
PANEL_SRC="${PANEL_SRC:-$HOME/petedio/palworld-panel}"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }
for t in vault ansible-playbook python3 bun; do command -v "$t" >/dev/null || die "$t not in PATH"; done
[ -f "$SECRETS/ansible.role_id" ] && [ -f "$SECRETS/ansible.secret_id" ] \
  || die "ansible AppRole creds not in $SECRETS."
[ -f "$PANEL_SRC/backend/src/index.ts" ] || die "panel source not at $PANEL_SRC (set PANEL_SRC)."
[ -f "$PANEL_SRC/frontend/package.json" ] || die "panel frontend not at $PANEL_SRC/frontend (set PANEL_SRC)."

step "Building the frontend (Vite — phone.html + dashboard.html)"
( cd "$PANEL_SRC/frontend" && bun install --frozen-lockfile && bun run build ) \
  || die "frontend build failed — see output above."

applogin(){ local rid sid; rid="$(cat "$SECRETS/$1.role_id")"; sid="$(cat "$SECRETS/$1.secret_id")"
  vault write -field=token auth/approle/login role_id="$rid" secret_id="$sid" 2>/dev/null || die "AppRole login failed for '$1'."; }

step "Resolving kv/services/palworld-panel (ansible AppRole)"
AN_TOKEN="$(applogin ansible)"
ADMIN_PW="$(VAULT_TOKEN="$AN_TOKEN" vault kv get -field=admin_password kv/services/palworld-panel)" || die "cannot read admin_password."
SSH_KEY="$(VAULT_TOKEN="$AN_TOKEN" vault kv get -field=panel_ssh_private_key kv/services/palworld-panel)" || die "cannot read panel_ssh_private_key."
[ -n "$ADMIN_PW" ] && [ -n "$SSH_KEY" ] || die "a required secret was empty."

step "Running configure-palworld-panel.yml (native deploy on 234)"
cd "$ANSIBLE_DIR"
EVARS="$(mktemp)"; chmod 600 "$EVARS"; trap 'rm -f "$EVARS"' EXIT
cat > "$EVARS" <<JSON
{
  "palworld_admin_password": $(printf '%s' "$ADMIN_PW" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))'),
  "panel_ssh_private_key": $(printf '%s' "$SSH_KEY" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))'),
  "palworld_panel_src": $(printf '%s' "$PANEL_SRC" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))')
}
JSON

ansible-playbook playbooks/configure-palworld-panel.yml -e "@$EVARS"

step "Done — panel deployed on 234:8080 (palworld.pdlab.dev once the route applies)."
