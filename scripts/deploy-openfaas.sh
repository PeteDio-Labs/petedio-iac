#!/usr/bin/env bash
# deploy-openfaas.sh — install/validate faasd on LXC 241, then CAPTURE faasd's own
# gateway password into Vault (kv/services/openfaas). (PET-86 driver)
#
# MODEL (capture, not push): configure-openfaas.yml does NOT set the gateway password —
# faasd generates and owns it (pushing our own value proved unreliable → gateway 401s).
# This wrapper runs the playbook, then reads faasd's generated password from the box and
# seeds it into Vault via reseed-openfaas-vault.sh (Keychain root token), so Vault is the
# source of truth for clients (faas-cli login, the future admin service, etc.).
#
# Run scripts/lxc-features-241.sh FIRST. Idempotent; no secrets printed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ANSIBLE_DIR="$REPO_ROOT/ansible"
OPENFAAS_HOST="${OPENFAAS_HOST:-192.168.50.241}"
OPENFAAS_SSH_KEY="${OPENFAAS_SSH_KEY:-$HOME/.ssh/id_ed25519_ansible}"

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }
for t in ansible-playbook ssh vault; do command -v "$t" >/dev/null || die "$t not in PATH"; done

step "Configure faasd on openfaas ($OPENFAAS_HOST)"
cd "$ANSIBLE_DIR"
ansible-playbook playbooks/configure-openfaas.yml

step "Capture faasd's gateway password -> Vault kv/services/openfaas"
# Read faasd's own generated password from the box (never printed) and hand it to the
# reseed script, which writes it to Vault with the Keychain root token (via stdin).
GW="$(ssh -i "$OPENFAAS_SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
        "root@$OPENFAAS_HOST" 'cat /var/lib/faasd/secrets/basic-auth-password')" \
  || die "could not read the gateway password from $OPENFAAS_HOST."
[ -n "$GW" ] || die "gateway password read empty."
GATEWAY_PASSWORD="$GW" "$SCRIPT_DIR/reseed-openfaas-vault.sh"

step "Done — faasd up on $OPENFAAS_HOST; gateway password captured to kv/services/openfaas."
echo "Gateway: http://$OPENFAAS_HOST:8080 (loopback on the box; expose publicly via PET-35/87)."
