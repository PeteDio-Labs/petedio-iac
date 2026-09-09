#!/usr/bin/env bash
# deploy-media-dash.sh — build mtrace and deploy it to media-dash-237 (PET-355).
#
# The by-hand twin of petedio-media-control's deploy.yml: same playbook, same extra-vars,
# same Vault path. CI runs it on merge; this is how an operator validates a change first.
#
# It compiles the binary HERE and the playbook copies it. There is no build on the target,
# on purpose — petedio-media-iac's roles/seerr calls a build-from-source Node app "the
# single riskiest operation in this stack", and `bun build --compile` exists precisely so
# this deploy is a file copy and a systemd restart.
#
# Secrets are resolved from Vault and passed as an extra-vars FILE, never on argv.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"
SRC="${MEDIA_CONTROL_SRC:-$HOME/petedio/media-control}"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
for t in vault ansible-playbook bun python3; do command -v "$t" >/dev/null || die "$t not in PATH."; done
[ -d "$SRC" ] || die "No petedio-media-control checkout at $SRC (set MEDIA_CONTROL_SRC)."

step "Resolving Vault token"
if [ -z "${VAULT_TOKEN:-}" ]; then
  VAULT_TOKEN="$(security find-generic-password -s "$VAULT_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null || true)"
fi
[ -n "${VAULT_TOKEN:-}" ] || { read -rsp "Vault token: " VAULT_TOKEN; echo; }
export VAULT_TOKEN
vault token lookup >/dev/null 2>&1 || die "Vault token invalid / Vault unreachable."

step "Compiling the binary"
( cd "$SRC" && bun install --frozen-lockfile >/dev/null && bun run build )
[ -x "$SRC/dist/mtrace" ] || die "bun run build produced no dist/mtrace."
ls -lh "$SRC/dist/mtrace"

step "Reading kv/services/media/dashboard"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
umask 077
vault kv get -format=json kv/services/media/dashboard \
  | python3 -c '
import json, sys, yaml
d = json.load(sys.stdin)["data"]["data"]
missing = [k for k in ("ssh_private_key", "ssh_public_key", "api_token") if not d.get(k)]
if missing:
    sys.exit("kv/services/media/dashboard is missing: " + ", ".join(missing) +
             " — run scripts/reseed-media-dash-vault.sh first.")
yaml.safe_dump({
    "media_dash_ssh_private_key": d["ssh_private_key"],
    "media_dash_ssh_public_key": d["ssh_public_key"],
    "mtrace_api_token": d["api_token"],
}, open(sys.argv[1], "w"))
' "$TMP/extra.yml"

step "Running configure-media-dash.yml"
cd "$REPO_ROOT/ansible"
ansible-playbook playbooks/configure-media-dash.yml \
  -e media_dash_binary_src="$SRC/dist/mtrace" \
  -e "@$TMP/extra.yml" \
  "$@"

step "Proving it answers"
curl -fsS --max-time 15 http://192.168.50.237:8237/health && echo
