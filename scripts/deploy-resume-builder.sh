#!/usr/bin/env bash
# deploy-resume-builder.sh — build the app locally, resolve its secrets from Vault, and run
# configure-resume-builder.yml, which deploys it natively on resume-242. (Resume Builder P1)
#
# Operator run (from a controller with the petedio-resume-builder checkout at $RESUME_SRC).
# Resolves under the ansible policy and passes as no_log extra-vars:
#   kv/services/resume-builder -> mongo_app_password, cf_access_team_domain, cf_access_aud,
#     allowed_users (falls back to soniasdelgadillo@gmail.com,pedelgadillo@gmail.com per the
#     planning doc's single-user-v1 allow-list if the field isn't seeded yet)
#   AppRole creds: $SECRETS_DIR/ansible.{role_id,secret_id} (gitignored .secrets/)
#   RESUME_SRC (optional): path to the petedio-resume-builder checkout (default ~/petedio/resume-builder)
#
# Manual-validation-first (standing convention, PET-266): this script IS the manual-deploy
# proof step. CD-on-merge only gets wired up after a run of this succeeds by hand.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"
SECRETS="${SECRETS_DIR:-$REPO_ROOT/.secrets}"
ANSIBLE_DIR="$REPO_ROOT/ansible"
RESUME_SRC="${RESUME_SRC:-$HOME/petedio/resume-builder}"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }
for t in vault ansible-playbook python3 bun; do command -v "$t" >/dev/null || die "$t not in PATH"; done
[ -f "$SECRETS/ansible.role_id" ] && [ -f "$SECRETS/ansible.secret_id" ] \
  || die "ansible AppRole creds not in $SECRETS."
[ -f "$RESUME_SRC/package.json" ] || die "app source not at $RESUME_SRC (set RESUME_SRC)."

applogin(){ local rid sid; rid="$(cat "$SECRETS/$1.role_id")"; sid="$(cat "$SECRETS/$1.secret_id")"
  vault write -field=token auth/approle/login role_id="$rid" secret_id="$sid" 2>/dev/null || die "AppRole login failed for '$1'."; }

step "Building the app (bun install + bun run build) at $RESUME_SRC"
(cd "$RESUME_SRC" && bun install && bun run build) || die "build failed."
[ -f "$RESUME_SRC/build/index.js" ] || die "build succeeded but $RESUME_SRC/build/index.js is missing — check the adapter-node output path."

step "Resolving kv/services/resume-builder (ansible AppRole)"
AN_TOKEN="$(applogin ansible)"
MONGO_PW="$(VAULT_TOKEN="$AN_TOKEN" vault kv get -field=mongo_app_password kv/services/resume-builder)" || die "cannot read mongo_app_password."
CF_TEAM_DOMAIN="$(VAULT_TOKEN="$AN_TOKEN" vault kv get -field=cf_access_team_domain kv/services/resume-builder 2>/dev/null || true)"
CF_AUD="$(VAULT_TOKEN="$AN_TOKEN" vault kv get -field=cf_access_aud kv/services/resume-builder 2>/dev/null || true)"
ALLOWED_USERS="$(VAULT_TOKEN="$AN_TOKEN" vault kv get -field=allowed_users kv/services/resume-builder 2>/dev/null || true)"
[ -n "$MONGO_PW" ] || die "mongo_app_password was empty."
[ -n "$CF_TEAM_DOMAIN" ] || die "cf_access_team_domain not seeded in kv/services/resume-builder yet — get it from the Authentik/CF Access setup (cloudflare-oidc.tf) and seed it first."
[ -n "$CF_AUD" ] || die "cf_access_aud not seeded — only exists once the cv.pdlab.dev Access application has actually applied (cloudflare-routes.tf); read it from the Cloudflare dashboard (Access > Applications > cv.pdlab.dev) and seed kv/services/resume-builder first."
# Single-user v1 default (planning doc §4/§10 decision 10) if the field isn't seeded yet.
ALLOWED_USERS="${ALLOWED_USERS:-soniasdelgadillo@gmail.com,pedelgadillo@gmail.com}"

step "Running configure-resume-builder.yml (native deploy on resume-242)"
cd "$ANSIBLE_DIR"
EVARS="$(mktemp)"; chmod 600 "$EVARS"; trap 'rm -f "$EVARS"' EXIT
cat > "$EVARS" <<JSON
{
  "resume_builder_mongo_password": $(printf '%s' "$MONGO_PW" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))'),
  "resume_builder_cf_access_team_domain": $(printf '%s' "$CF_TEAM_DOMAIN" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))'),
  "resume_builder_cf_access_aud": $(printf '%s' "$CF_AUD" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))'),
  "resume_builder_allowed_users": $(printf '%s' "$ALLOWED_USERS" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))'),
  "resume_builder_src": $(printf '%s' "$RESUME_SRC" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))')
}
JSON

ansible-playbook playbooks/configure-resume-builder.yml -e "@$EVARS"

step "Done — app deployed on resume-242:8080 (cv.pdlab.dev once the route + Mongo + this have all applied)."
