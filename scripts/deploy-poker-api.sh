#!/usr/bin/env bash
# deploy-poker-api.sh — resolve the Co-latro rollout secrets from Vault and run
# configure-poker-api.yml against LXC 230. (PET-44 driver)
#
# Follows the repo convention (reseed/import scripts): resolve secrets BEFORE the
# playbook and pass them as no_log extra-vars. DATABASE_URL is NO LONGER resolved here —
# since PET-57 a Vault Agent on 230 renders it to a tmpfs env-file from kv/poker/db
# directly (so it's never at rest / never flows through the deploy). This script now
# resolves only the deploy-time secrets the playbook still needs, all under the ansible
# policy:
#   - kv/services/{nexus,minio-frontend}    -> ansible AppRole (policy: ansible)
#
# OPERATOR path (run from the Mac). The runner/OIDC CD-on-merge path is a fast-follow:
# ci-read currently reads poker/* but NOT services/* — grant that before moving here.
#
# Idempotent; no secrets printed. Run PET-43 (scripts/lxc-features-230.sh) FIRST.
#   AppRole creds: $SECRETS_DIR/ansible.{role_id,secret_id} (gitignored .secrets/)
#   Optional: -e backend_image_tag=<sha> passthrough via $IMAGE_TAG
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
for t in vault ansible-playbook; do command -v "$t" >/dev/null || die "$t not in PATH"; done
for r in ansible; do
  [ -f "$SECRETS/$r.role_id" ] && [ -f "$SECRETS/$r.secret_id" ] \
    || die "AppRole creds for '$r' not in $SECRETS (see vault-seed.md)."
done

# This script resolves only kv/services/* (nexus + minio-frontend), all under the ansible
# policy. DATABASE_URL (kv/poker/db) is rendered on-host by the poker-api Vault Agent
# (PET-57), not here — the ansible policy is deliberately NOT granted poker/*.
applogin(){ # $1=role  -> echoes a token
  local rid sid
  rid="$(cat "$SECRETS/$1.role_id")"; sid="$(cat "$SECRETS/$1.secret_id")"
  vault write -field=token auth/approle/login role_id="$rid" secret_id="$sid" 2>/dev/null \
    || die "AppRole login failed for '$1'."
}

step "Resolving kv/services/* (ansible AppRole)"
AN_TOKEN="$(applogin ansible)"
NEXUS_U="$(VAULT_TOKEN="$AN_TOKEN" vault kv get -field=username kv/services/nexus 2>/dev/null || echo admin)"
NEXUS_P="$(VAULT_TOKEN="$AN_TOKEN" vault kv get -field=admin_password kv/services/nexus)" || die "cannot read kv/services/nexus."
MINIO_AK="$(VAULT_TOKEN="$AN_TOKEN" vault kv get -field=access_key kv/services/minio-frontend)" \
  || die "cannot read kv/services/minio-frontend — run scripts/reseed-minio-frontend-vault.sh first."
MINIO_SK="$(VAULT_TOKEN="$AN_TOKEN" vault kv get -field=secret_key kv/services/minio-frontend)" || die "cannot read minio-frontend secret_key."
[ -n "$NEXUS_P" ] && [ -n "$MINIO_AK" ] && [ -n "$MINIO_SK" ] || die "a required secret was empty."

# PET-87: admin-portal UI bucket creds (co-latro-admin-ui) — OPTIONAL. When kv/services/minio-admin-ui
# is unseeded the playbook skips the admin-UI sync (frontend-only deploy stays green). Seed with
# scripts/reseed-minio-admin-ui-vault.sh to enable the admin.pdlab.dev portal sync.
MINIO_ADMIN_AK="$(VAULT_TOKEN="$AN_TOKEN" vault kv get -field=access_key kv/services/minio-admin-ui 2>/dev/null || true)"
MINIO_ADMIN_SK="$(VAULT_TOKEN="$AN_TOKEN" vault kv get -field=secret_key kv/services/minio-admin-ui 2>/dev/null || true)"

step "Running configure-poker-api.yml against poker-api (230)"
EXTRA_TAG=()
[ -n "${IMAGE_TAG:-}" ] && EXTRA_TAG=(-e "backend_image_tag=$IMAGE_TAG")

cd "$ANSIBLE_DIR"
# Pass secrets via a JSON extra-vars file on a private tmp path (never argv, never logged).
EVARS="$(mktemp)"; chmod 600 "$EVARS"; trap 'rm -f "$EVARS"' EXIT
cat > "$EVARS" <<JSON
{
  "nexus_username": $(printf '%s' "$NEXUS_U" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))'),
  "nexus_password": $(printf '%s' "$NEXUS_P" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))'),
  "minio_frontend_access_key": $(printf '%s' "$MINIO_AK" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))'),
  "minio_frontend_secret_key": $(printf '%s' "$MINIO_SK" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))'),
  "minio_admin_ui_access_key": $(printf '%s' "$MINIO_ADMIN_AK" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))'),
  "minio_admin_ui_secret_key": $(printf '%s' "$MINIO_ADMIN_SK" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))')
}
JSON

ansible-playbook playbooks/configure-poker-api.yml -e "@$EVARS" "${EXTRA_TAG[@]}"

step "Done — Co-latro rolled out to LXC 230."
echo "Smoke test: see docs/runbooks/poker-api-deploy.md."
