#!/usr/bin/env bash
# deploy-uptime-kuma.sh — resolve the Uptime Kuma admin credentials from Vault and
# run configure-pete-pi.yml against Pete-Pi (PET-300).
#
# Operator run. Manual-validation-first (standing convention, PET-266): this script
# IS the manual-deploy proof; nothing is wired to CD-on-merge until a run is green.
#
# CREDENTIAL FLOW
#   kv/services/uptime-kuma  admin_user / admin_password
#     * CREATED here on first run under the Keychain root token, because the ansible
#       AppRole policy grants read on kv/data/services/* and deliberately not write.
#     * READ on every run under the ansible AppRole, like every other deploy.
#   The password is ALSO mirrored into the macOS Keychain. That is not belt-and-
#   braces: sealing Vault is one of the faults this study injects, and the operator
#   needs the monitoring UI most precisely while Vault is sealed. Same reasoning
#   that keeps Vault's own unseal key in the Keychain and not in Vault.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"
SECRETS="${SECRETS_DIR:-$REPO_ROOT/.secrets}"
ANSIBLE_DIR="$REPO_ROOT/ansible"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"

KUMA_PATH="kv/services/uptime-kuma"
KC_SERVICE="uptime-kuma-admin"
KC_ACCOUNT="pete-pi"

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }
for t in vault ansible-playbook python3 security; do
  command -v "$t" >/dev/null || die "$t not in PATH"
done
[ -f "$SECRETS/ansible.role_id" ] && [ -f "$SECRETS/ansible.secret_id" ] \
  || die "ansible AppRole creds not in $SECRETS."

step "Vault: check whether the admin secret exists yet"
ROOT_TOKEN="$(security find-generic-password -s vault-root-token -a vault-223 -w 2>/dev/null)" \
  || die "Vault root token not in the Keychain (service vault-root-token, account vault-223)."

if ! VAULT_TOKEN="$ROOT_TOKEN" vault kv get "$KUMA_PATH" >/dev/null 2>&1; then
  step "Vault: seeding $KUMA_PATH (first run)"
  # 32 URL-safe chars. Generated here and never printed.
  NEW_PW="$(python3 -c 'import secrets;print(secrets.token_urlsafe(24))')"
  VAULT_TOKEN="$ROOT_TOKEN" vault kv put "$KUMA_PATH" \
    admin_user="pedro" admin_password="$NEW_PW" >/dev/null \
    || die "could not write $KUMA_PATH"
  security add-generic-password -U -s "$KC_SERVICE" -a "$KC_ACCOUNT" -w "$NEW_PW" \
    || die "could not mirror the password into the Keychain"
  unset NEW_PW
  echo "  seeded, and mirrored into the Keychain."
else
  echo "  already present — reusing it."
fi

step "Vault: log in as the ansible AppRole"
RID="$(cat "$SECRETS/ansible.role_id")"; SID="$(cat "$SECRETS/ansible.secret_id")"
AN_TOKEN="$(VAULT_TOKEN="$ROOT_TOKEN" vault write -field=token auth/approle/login \
  role_id="$RID" secret_id="$SID" 2>/dev/null)" || die "AppRole login failed."

step "Vault: resolve the admin credentials"
KUMA_USER="$(VAULT_TOKEN="$AN_TOKEN" vault kv get -field=admin_user "$KUMA_PATH")" \
  || die "cannot read $KUMA_PATH field 'admin_user'."
KUMA_PW="$(VAULT_TOKEN="$AN_TOKEN" vault kv get -field=admin_password "$KUMA_PATH")" \
  || die "cannot read $KUMA_PATH field 'admin_password'."

# Keep the Keychain mirror in step with Vault if the password was rotated there.
security add-generic-password -U -s "$KC_SERVICE" -a "$KC_ACCOUNT" -w "$KUMA_PW" 2>/dev/null || true

step "Ansible: configure-pete-pi.yml"
cd "$ANSIBLE_DIR"
ansible-playbook playbooks/configure-pete-pi.yml \
  -e "uptime_kuma_admin_user=$KUMA_USER" \
  -e "uptime_kuma_admin_password=$KUMA_PW" \
  "$@"

step "Done"
cat <<'EOF'
  UI            http://192.168.50.4:3001
  Credentials   Vault kv/services/uptime-kuma (admin_user / admin_password)
                mirrored: security find-generic-password -s uptime-kuma-admin -a pete-pi -w
EOF
