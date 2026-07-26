#!/usr/bin/env bash
# deploy-water-fast.sh — build the frontend locally, resolve the app's secrets from Vault,
# and run configure-water-fast.yml, which deploys it natively on waterfast-243.
#
# Operator run (from a controller with the petedio-water-fast checkout at $WATERFAST_SRC).
# Resolves under the ansible policy and passes as no_log extra-vars:
#   kv/services/water-fast -> db_password, cf_access_team_domain, cf_access_aud
#   AppRole creds: $SECRETS_DIR/ansible.{role_id,secret_id} (gitignored .secrets/)
#   WATERFAST_SRC (optional): path to the checkout (default ~/petedio/water-fast)
#
# Manual-validation-first (standing convention, PET-266): this script IS the manual-deploy
# proof step. CD-on-merge only gets wired up after a run of this succeeds by hand.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"
SECRETS="${SECRETS_DIR:-$REPO_ROOT/.secrets}"
ANSIBLE_DIR="$REPO_ROOT/ansible"
WATERFAST_SRC="${WATERFAST_SRC:-$HOME/petedio/water-fast}"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }
for t in vault ansible-playbook python3 bun; do command -v "$t" >/dev/null || die "$t not in PATH"; done
[ -f "$SECRETS/ansible.role_id" ] && [ -f "$SECRETS/ansible.secret_id" ] \
  || die "ansible AppRole creds not in $SECRETS."
[ -f "$WATERFAST_SRC/package.json" ] || die "app source not at $WATERFAST_SRC (set WATERFAST_SRC)."

applogin(){ local rid sid; rid="$(cat "$SECRETS/$1.role_id")"; sid="$(cat "$SECRETS/$1.secret_id")"
  vault write -field=token auth/approle/login role_id="$rid" secret_id="$sid" 2>/dev/null || die "AppRole login failed for '$1'."; }

# The backend is TypeScript that bun runs directly, but the frontend is a Vite bundle and the
# play copies frontend/dist/ rather than building on the target. `bun run build` runs
# `tsc --noEmit` first, so this also catches any drift between shared/types.ts and either side.
step "Building the frontend at $WATERFAST_SRC"
(cd "$WATERFAST_SRC" && bun install && cd frontend && bun run build) || die "frontend build failed."
[ -f "$WATERFAST_SRC/frontend/dist/index.html" ] || die "build succeeded but frontend/dist/index.html is missing."

step "Resolving kv/services/water-fast (ansible AppRole)"
AN_TOKEN="$(applogin ansible)"
DB_PW="$(VAULT_TOKEN="$AN_TOKEN" vault kv get -field=db_password kv/services/water-fast)" || die "cannot read db_password."
CF_TEAM_DOMAIN="$(VAULT_TOKEN="$AN_TOKEN" vault kv get -field=cf_access_team_domain kv/services/water-fast 2>/dev/null || true)"
CF_AUD="$(VAULT_TOKEN="$AN_TOKEN" vault kv get -field=cf_access_aud kv/services/water-fast 2>/dev/null || true)"

[ -n "$DB_PW" ] || die "db_password was empty."
[ -n "$CF_TEAM_DOMAIN" ] || die "cf_access_team_domain not seeded in kv/services/water-fast — it's the Zero Trust team domain (no protocol), same value the other apps use."
# No default for the AUD on purpose: it only exists after the fast.pdlab.dev Access
# application has applied, and a blank one would deploy a service that 401s every request
# while looking healthy — the failure would surface as "nobody can log in", far from here.
[ -n "$CF_AUD" ] || die "cf_access_aud not seeded — only exists once the fast.pdlab.dev Access application has applied (cloudflare-routes.tf). Read it from the Cloudflare dashboard (Access > Applications > fast.pdlab.dev) and seed kv/services/water-fast first."

step "Running configure-water-fast.yml (native deploy on waterfast-243)"
cd "$ANSIBLE_DIR"
EVARS="$(mktemp)"; chmod 600 "$EVARS"; trap 'rm -f "$EVARS"' EXIT
cat > "$EVARS" <<JSON
{
  "waterfast_db_password": $(printf '%s' "$DB_PW" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))'),
  "waterfast_cf_access_team_domain": $(printf '%s' "$CF_TEAM_DOMAIN" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))'),
  "waterfast_cf_access_aud": $(printf '%s' "$CF_AUD" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))'),
  "waterfast_src": $(printf '%s' "$WATERFAST_SRC" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))')
}
JSON

ansible-playbook playbooks/configure-water-fast.yml -e "@$EVARS"

step "Done — app deployed on waterfast-243:8080 (fast.pdlab.dev once the route + DB + this have all applied)."
