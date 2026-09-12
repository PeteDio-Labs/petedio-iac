#!/usr/bin/env bash
# deploy-claude-loop.sh — resolve the work loop's identity from Vault and run
# configure-claude-code.yml against LXC 247 (PET-399).
#
# Operator run, from YOUR machine. This is the wrapper that keeps 247 free of a Vault
# credential: the AppRole login happens here, the fields are resolved here, and the host
# receives only the two secrets it needs, as root-owned 0400 files. There is no role_id or
# secret_id on 247, and there is no Vault Agent — that was the retired fleet's shape and it
# put a renewable Vault token on a box whose sessions run in bypassPermissions.
#
#   kv/services/claude-loop -> app_id, installation_id, app_pem   (the bot identity)
#   kv/services/plane       -> api_key                            (the PAT CI already uses)
#   AppRole creds: $SECRETS_DIR/ansible.{role_id,secret_id} (gitignored .secrets/)
#
# The `ansible` policy already grants read on kv/data/services/* — see
# environments/homelab/vault-config/policies.tf. NO vault-config change is needed for this,
# and a plan that proposes one is repointing something else.
#
#   ./scripts/deploy-claude-loop.sh                            # land the identity, timer off
#   ./scripts/deploy-claude-loop.sh -e claude_loop_enable=true # ... and start the timer
#
# ⚠ TURNING THE TIMER ON IS A SEPARATE DECISION FROM LANDING THE CREDENTIAL, which is why
# it is a flag you type and not the default. Run the tick by hand once first —
# docs/runbooks/claude-loop.md, "Before you enable it".
#
# Manual-validation-first (standing convention, PET-266): this script IS the manual-deploy
# proof step. Nothing in .github/workflows watches configure-claude-code.yml.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"
SECRETS="${SECRETS_DIR:-$REPO_ROOT/.secrets}"
ANSIBLE_DIR="$REPO_ROOT/ansible"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"

PLANE_BASE_URL="${PLANE_BASE_URL:-http://192.168.50.235:8080}"
PLANE_WORKSPACE="${PLANE_WORKSPACE:-petedio}"
PLANE_IDENTIFIER="${PLANE_IDENTIFIER:-PET}"

step() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die() { printf '\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }

for t in vault ansible-playbook python3 curl; do command -v "$t" >/dev/null || die "$t not in PATH"; done
[ -f "$SECRETS/ansible.role_id" ] && [ -f "$SECRETS/ansible.secret_id" ] \
  || die "ansible AppRole creds not in $SECRETS."

applogin() {
  local rid sid
  rid="$(cat "$SECRETS/$1.role_id")"
  sid="$(cat "$SECRETS/$1.secret_id")"
  vault write -field=token auth/approle/login role_id="$rid" secret_id="$sid" 2>/dev/null \
    || die "AppRole login failed for '$1'."
}

step "Resolving the loop identity (ansible AppRole)"
AN_TOKEN="$(applogin ansible)"
kvget() { VAULT_TOKEN="$AN_TOKEN" vault kv get -field="$2" "$1" 2>/dev/null || true; }

APP_ID="$(kvget kv/services/claude-loop app_id)"
INSTALL_ID="$(kvget kv/services/claude-loop installation_id)"
APP_PEM="$(kvget kv/services/claude-loop app_pem)"
PLANE_KEY="$(kvget kv/services/plane api_key)"

# No fallbacks and no placeholders, on purpose. Every one of these lands on the host as a
# 0400 file that LOOKS provisioned; a blank or guessed value would not fail here, it would
# fail at the first tick, at 03:00, in a unit nobody is watching.
[ -n "$APP_ID" ] || die "app_id missing from kv/services/claude-loop — seed it first (docs/runbooks/claude-loop.md)."
[ -n "$INSTALL_ID" ] || die "installation_id missing from kv/services/claude-loop."
[ -n "$APP_PEM" ] || die "app_pem missing from kv/services/claude-loop."
[ -n "$PLANE_KEY" ] || die "api_key missing from kv/services/plane — the same PAT CI uses."

# A PEM that survived a copy-paste as one line signs nothing, and openssl's complaint about
# it points at the signature, not the field. Check the shape here, where the fix is obvious.
printf '%s' "$APP_PEM" | grep -q -- "-----BEGIN .*PRIVATE KEY-----" \
  || die "app_pem does not look like a PEM private key. Re-seed it with the .pem file GitHub gave you, newlines intact."
[ "$(printf '%s' "$APP_PEM" | wc -l)" -ge 3 ] \
  || die "app_pem is a single line — its newlines were lost on the way into Vault. Re-seed it."

# ⚠ These two MUST be different Apps' worth of care even though there is only one App here:
# app_id identifies the App, installation_id identifies its install on ONE repo. Swapping
# them mints nothing and reports a 404 that reads like a missing App.
printf 'app %s, installation %s, pem %s bytes, plane PAT %s bytes\n' \
  "$APP_ID" "$INSTALL_ID" "${#APP_PEM}" "${#PLANE_KEY}"

step "Resolving the Plane project id for '$PLANE_IDENTIFIER'"
# Looked up rather than pinned. A project UUID would have to be re-pinned every time the
# project is recreated, which plane-bootstrap.sh already learned once. The PAT goes to curl
# through stdin so it never reaches argv.
PROJECTS="$(printf 'X-API-Key: %s\n' "$PLANE_KEY" | curl -sS --max-time 20 -H @- \
  "${PLANE_BASE_URL%/}/api/v1/workspaces/${PLANE_WORKSPACE}/projects/" 2>/dev/null)" \
  || die "Plane unreachable at $PLANE_BASE_URL — is the tailnet up?"

PROJECT_ID="$(printf '%s' "$PROJECTS" | PLANE_IDENTIFIER="$PLANE_IDENTIFIER" python3 -c '
import json, os, sys
want = os.environ["PLANE_IDENTIFIER"].upper()
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
rows = d if isinstance(d, list) else (d.get("results") or [])
for p in rows:
    if str(p.get("identifier", "")).upper() == want:
        print(p["id"])
        break
')"
[ -n "$PROJECT_ID" ] || die "no project with identifier '$PLANE_IDENTIFIER' in workspace '$PLANE_WORKSPACE'."
printf 'project %s\n' "$PROJECT_ID"

step "Running configure-claude-code.yml (the loop identity on claude-247)"
cd "$ANSIBLE_DIR"
# umask BEFORE the temp file exists, so the extra-vars never sit world-readable. mktemp -d
# gives a 0700 parent, but the file inside it inherits the process umask.
umask 077
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# JSON, not YAML, and built by python rather than printf: a PEM is multi-line and full of
# characters that are a valid private key and an invalid bare YAML scalar.
#
# Every value travels in the ENVIRONMENT, never in argv — `ps` on a shared machine reads
# argv, and one of these is an App private key.
OUT="$TMP/extra.json" \
APP_ID="$APP_ID" INSTALL_ID="$INSTALL_ID" APP_PEM="$APP_PEM" \
PLANE_KEY="$PLANE_KEY" PLANE_BASE_URL="$PLANE_BASE_URL" \
PLANE_WORKSPACE="$PLANE_WORKSPACE" PROJECT_ID="$PROJECT_ID" \
python3 -c '
import json, os
json.dump({
    "claude_loop_github_app_id": os.environ["APP_ID"],
    "claude_loop_github_installation_id": os.environ["INSTALL_ID"],
    "claude_loop_github_app_pem": os.environ["APP_PEM"],
    "claude_loop_plane_api_key": os.environ["PLANE_KEY"],
    "claude_loop_plane_base_url": os.environ["PLANE_BASE_URL"],
    "claude_loop_plane_workspace": os.environ["PLANE_WORKSPACE"],
    "claude_loop_plane_project_id": os.environ["PROJECT_ID"],
}, open(os.environ["OUT"], "w"))
' || die "could not write the extra-vars file."
unset APP_PEM PLANE_KEY

ansible-playbook playbooks/configure-claude-code.yml -e "@$TMP/extra.json" "$@"

step "Done"
cat <<'TXT'
  Re-run this script to confirm idempotence — a converged host must report changed=0.

  The timer is OFF unless you passed -e claude_loop_enable=true. Before you turn it on,
  run one tick by hand and read what it did:

    ssh claude@192.168.50.247 'sudo -n /usr/local/sbin/claude-loop-broker next-item'
    ssh claude@192.168.50.247 '~/loop/claude-loop-tick.sh'
    ssh claude@192.168.50.247 'cat ~/loop/state/last-tick.json'

  Then, once a draft PR from the bot looks right:

    ./scripts/deploy-claude-loop.sh -e claude_loop_enable=true
    ./scripts/lab-verify.sh | grep -i loop

  Full sequence, including how to pause and how to rotate the App key:
  docs/runbooks/claude-loop.md
TXT
