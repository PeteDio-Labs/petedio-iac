#!/usr/bin/env bash
# deploy-codex-248.sh — resolve codex-248's two reviewer identities from Vault and run
# configure-codex.yml against it (PET-553). Modeled on deploy-claude-247.sh.
#
#   kv/services/codex-review-app -> app_id, installation_id, app_pem   (optional)
#     The petedio-codex-review GitHub App. contents:read, pull_requests:write and
#     metadata:read, on every PeteDio-Labs repository. Seeded by seed-codex-review-app.sh.
#   kv/services/codex-plane      -> api_key                            (optional)
#     The `codex` Plane user's token. Seeded by seed-codex-plane-token.sh.
#
# An absent identity is a warning, and the play leaves that one's files on the host as they
# are. Both absent is a plain configure run.
#
#   AppRole creds: $SECRETS_DIR/ansible.{role_id,secret_id} (gitignored .secrets/)
#
# Operator run, from your machine. The AppRole login happens here, so codex-248 holds no
# Vault credential: it receives only the files it needs, 0400 and owned by the session user.
#
# The fields reach jq through its environment, never argv, because `ps` reads argv. The
# extra-vars file lives in a 0700 temp directory and is deleted on exit.
#
#   ./scripts/deploy-codex-248.sh [extra ansible-playbook args, such as --check --diff]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"
SECRETS="${SECRETS_DIR:-$REPO_ROOT/.secrets}"
ANSIBLE_DIR="$REPO_ROOT/ansible"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"

step() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARNING: %s\033[0m\n' "$*" >&2; }
die() { printf '\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }

for t in vault jq ansible-playbook; do command -v "$t" >/dev/null || die "$t not in PATH"; done
[ -f "$SECRETS/ansible.role_id" ] && [ -f "$SECRETS/ansible.secret_id" ] \
  || die "ansible AppRole creds not in $SECRETS."

step "Reading codex-248's identities from Vault (ansible AppRole)"
AN_TOKEN="$(vault write -field=token auth/approle/login \
  role_id="$(cat "$SECRETS/ansible.role_id")" secret_id="$(cat "$SECRETS/ansible.secret_id")" 2>/dev/null)" \
  || die "AppRole login failed for 'ansible'. Run ./scripts/pet-secrets doctor to see whether Vault is sealed."
kvget() { VAULT_TOKEN="$AN_TOKEN" vault kv get -field="$2" "$1" 2>/dev/null || true; }

CODEX_APP_ID="$(kvget kv/services/codex-review-app app_id)"
CODEX_INSTALL_ID="$(kvget kv/services/codex-review-app installation_id)"
CODEX_APP_PEM="$(kvget kv/services/codex-review-app app_pem)"
CODEX_PLANE_KEY="$(kvget kv/services/codex-plane api_key)"
unset AN_TOKEN

# Both-or-nothing per identity: a partial App identity mints nothing.
if [ -n "$CODEX_APP_ID$CODEX_INSTALL_ID$CODEX_APP_PEM" ]; then
  [ -n "$CODEX_APP_ID" ] && [ -n "$CODEX_INSTALL_ID" ] && [ -n "$CODEX_APP_PEM" ] \
    || die "kv/services/codex-review-app is partial. Run ./scripts/seed-codex-review-app.sh again."
  case "$CODEX_APP_ID$CODEX_INSTALL_ID" in *[!0-9]*) die "kv/services/codex-review-app holds a non-numeric id." ;; esac
  [ "$(printf '%s\n' "$CODEX_APP_PEM" | wc -l | tr -d ' ')" -ge 3 ] \
    || die "kv/services/codex-review-app app_pem lost its newlines. Run ./scripts/seed-codex-review-app.sh again."
  echo "  GitHub App: app_id=$CODEX_APP_ID installation_id=$CODEX_INSTALL_ID"
else
  warn "kv/services/codex-review-app is not seeded. The play leaves the App identity on the host as it is."
fi
if [ -n "$CODEX_PLANE_KEY" ]; then
  echo "  Plane token: present"
else
  warn "kv/services/codex-plane is not seeded. The play leaves the Plane token on the host as it is."
fi
export CODEX_APP_ID CODEX_INSTALL_ID CODEX_APP_PEM CODEX_PLANE_KEY

umask 077
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
jq -n '{
  codex_review_app_id: env.CODEX_APP_ID,
  codex_review_installation_id: env.CODEX_INSTALL_ID,
  codex_review_app_pem: env.CODEX_APP_PEM,
  codex_plane_api_key: env.CODEX_PLANE_KEY
}' > "$TMP/extra.json"
unset CODEX_APP_PEM CODEX_PLANE_KEY

step "Running configure-codex.yml"
cd "$ANSIBLE_DIR"
ansible-playbook playbooks/configure-codex.yml -e "@$TMP/extra.json" "$@"

step "Done"
cat <<'TXT'
  Run this script again to confirm idempotence: a converged host reports changed=0.

  To prove the identities from the host:
    ssh -i ~/.ssh/id_ed25519_pedro codex@192.168.50.248 'codex-review-broker mint-token petedio-iac >/dev/null && echo minted'
    ssh -i ~/.ssh/id_ed25519_pedro codex@192.168.50.248 'plane get PET-553 | head -3'
TXT
