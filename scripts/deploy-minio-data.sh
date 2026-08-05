#!/usr/bin/env bash
# deploy-minio-data.sh — resolve the app-data MinIO's root credentials from Vault and run
# configure-minio-data.yml against LXC 245.
#
# Operator run. Resolves under the ansible policy (which already reads kv/data/iac/*, so
# no vault-config change was needed for this host) and passes as no_log extra-vars:
#   kv/iac/minio-data-root -> root_user, root_password
#   AppRole creds: $SECRETS_DIR/ansible.{role_id,secret_id} (gitignored .secrets/)
#
# Manual-validation-first (standing convention, PET-266): this script IS the manual-deploy
# proof step. CD-on-merge only gets wired up after a run of this succeeds by hand.
#
# This is the .245 sibling of the .221 flow documented in roles/minio/README.md. It will
# NOT touch .221: the play targets the `minio_data` inventory group only.
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
  || die "ansible AppRole creds not in $SECRETS."

applogin(){ local rid sid; rid="$(cat "$SECRETS/$1.role_id")"; sid="$(cat "$SECRETS/$1.secret_id")"
  vault write -field=token auth/approle/login role_id="$rid" secret_id="$sid" 2>/dev/null || die "AppRole login failed for '$1'."; }

step "Resolving kv/iac/minio-data-root (ansible AppRole)"
AN_TOKEN="$(applogin ansible)"
ROOT_U="$(VAULT_TOKEN="$AN_TOKEN" vault kv get -field=root_user kv/iac/minio-data-root 2>/dev/null || true)"
ROOT_P="$(VAULT_TOKEN="$AN_TOKEN" vault kv get -field=root_password kv/iac/minio-data-root 2>/dev/null || true)"

# No fallback and no placeholder, on purpose: the role writes these into
# /etc/default/minio as the LIVE root account, so a blank or guessed value would not fail
# loudly — it would stand up a MinIO whose admin credential nobody holds.
[ -n "$ROOT_U" ] || die "root_user missing from kv/iac/minio-data-root — run ./scripts/seed-minio-data-root.sh first."
[ -n "$ROOT_P" ] || die "root_password missing from kv/iac/minio-data-root — run ./scripts/seed-minio-data-root.sh first."
[ ${#ROOT_P} -ge 8 ] || die "root_password is shorter than the role's assert allows (${#ROOT_P} chars)."

step "Running configure-minio-data.yml (MinIO + buckets on minio-data-245)"
cd "$ANSIBLE_DIR"
EVARS="$(mktemp)"; chmod 600 "$EVARS"; trap 'rm -f "$EVARS"' EXIT
cat > "$EVARS" <<JSON
{
  "minio_root_user": $(printf '%s' "$ROOT_U" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))'),
  "minio_root_password": $(printf '%s' "$ROOT_P" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))')
}
JSON
unset ROOT_P

ansible-playbook playbooks/configure-minio-data.yml -e "@$EVARS" "$@"

step "Done"
cat <<'TXT'
  Re-run this script to confirm idempotence — a converged host must report changed=0.

  Then, if this is a first build:
    ./scripts/reseed-minio-obsidian-vault.sh   # mint the bucket-scoped sync credential

  Health check (needs the tailnet up):
    curl -s -o /dev/null -w '%{http_code}\n' http://192.168.50.245:9000/minio/health/ready
TXT
