#!/usr/bin/env bash
# deploy-openfaas.sh — install/validate faasd on LXC 241, configure its private-registry
# (Nexus) pull auth, then CAPTURE faasd's own gateway password into Vault. (PET-86/88 driver)
#
# MODEL (capture, not push): configure-openfaas.yml does NOT set the gateway password —
# faasd generates and owns it (pushing our own value proved unreliable → gateway 401s).
# This wrapper runs the playbook, then reads faasd's generated password from the box and
# seeds it into Vault (kv/services/openfaas) via reseed-openfaas-vault.sh, so Vault is the
# source of truth for clients (faas-cli login, the admin functions, etc.).
#
# REGISTRY (PET-88): resolves nexus_username/nexus_password (Vault kv/services/nexus) and
# passes them as no_log extra-vars so the play can write /var/lib/faasd/.docker/config.json
# (faasd/containerd pulls our function images from docker.pdlab.dev).
#
# Run scripts/lxc-features-241.sh FIRST. Idempotent; no secrets printed.
#   Vault token: $VAULT_TOKEN, else macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM, else prompt.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"
ANSIBLE_DIR="$REPO_ROOT/ansible"
OPENFAAS_HOST="${OPENFAAS_HOST:-192.168.50.241}"
OPENFAAS_SSH_KEY="${OPENFAAS_SSH_KEY:-$HOME/.ssh/id_ed25519_ansible}"
export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }
for t in ansible-playbook ssh vault python3; do command -v "$t" >/dev/null || die "$t not in PATH"; done

step "Resolve Nexus pull creds (Vault kv/services/nexus)"
if [ -z "${VAULT_TOKEN:-}" ]; then
  VAULT_TOKEN="$(security find-generic-password -s "$VAULT_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null || true)"
fi
[ -n "${VAULT_TOKEN:-}" ] || { read -rsp 'Vault token: ' VAULT_TOKEN; echo; }
export VAULT_TOKEN
vault token lookup >/dev/null 2>&1 || die "Vault token invalid / Vault unreachable."
NEXUS_U="$(vault kv get -field=username kv/services/nexus 2>/dev/null || echo admin)"
NEXUS_P="$(vault kv get -field=admin_password kv/services/nexus)" || die "cannot read kv/services/nexus."
[ -n "$NEXUS_P" ] || die "nexus password read empty."

step "Configure faasd on openfaas ($OPENFAAS_HOST)"
cd "$ANSIBLE_DIR"
# Secrets via a JSON extra-vars file on a private tmp path (never argv, never logged).
EVARS="$(mktemp)"; chmod 600 "$EVARS"; trap 'rm -f "$EVARS"' EXIT
cat > "$EVARS" <<JSON
{
  "nexus_username": $(printf '%s' "$NEXUS_U" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))'),
  "nexus_password": $(printf '%s' "$NEXUS_P" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))')
}
JSON
ansible-playbook playbooks/configure-openfaas.yml -e "@$EVARS"

step "Capture faasd's gateway password -> Vault kv/services/openfaas"
# Read faasd's own generated password from the box (never printed) and hand it to the
# reseed script, which writes it to Vault (uses the same exported VAULT_TOKEN).
GW="$(ssh -i "$OPENFAAS_SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
        "root@$OPENFAAS_HOST" 'cat /var/lib/faasd/secrets/basic-auth-password')" \
  || die "could not read the gateway password from $OPENFAAS_HOST."
[ -n "$GW" ] || die "gateway password read empty."
GATEWAY_PASSWORD="$GW" "$SCRIPT_DIR/reseed-openfaas-vault.sh"

step "Done — faasd up on $OPENFAAS_HOST; Nexus pull auth configured; gateway password captured."
# PET-203 (F1): the faasd compose binds the gateway 0.0.0.0:8080 (it loopback-binds prometheus but
# NOT the gateway), and 241 has no host/NIC firewall — so the full OpenFaaS CONTROL PLANE is reachable
# by anything on 192.168.50.0/24 with the basic-auth (confirmed: 241:8080/system/functions -> 401 from
# a non-230 LAN host). This is NOT loopback-only. Restrict :8080 to 192.168.50.230 (Proxmox VNIC
# firewall) or loopback-bind + reverse-proxy only /function/invites — tracked in the PET-203 follow-up.
echo "Gateway: http://$OPENFAAS_HOST:8080 (LAN-exposed *:8080 — restrict to 230; see PET-203)."
