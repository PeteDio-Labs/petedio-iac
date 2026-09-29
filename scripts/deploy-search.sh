#!/usr/bin/env bash
# deploy-search.sh — build petedio-search and deploy it to ollama-host (PET-526).
#
# It compiles the binary here, for Linux x86-64, and the playbook copies it. Nothing
# builds on the target.
#
# Secrets come from Vault kv/services/search (minted by scripts/search-secrets.sh) and
# kv/services/claude-workspace-mirror (the GitHub App that reads the vault, PET-542), and
# reach ansible-playbook as an extra-vars FILE, never on argv.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"
SRC="${SEARCH_SRC:-$HOME/petedio/search}"
SECRET_PATH="kv/services/search"
APP_PATH="kv/services/claude-workspace-mirror"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
for t in vault ansible-playbook bun python3; do command -v "$t" >/dev/null || die "$t not in PATH."; done
[ -d "$SRC" ] || die "No petedio-search checkout at $SRC (set SEARCH_SRC)."

step "Resolving Vault token"
if [ -z "${VAULT_TOKEN:-}" ]; then
  VAULT_TOKEN="$(security find-generic-password -s "$VAULT_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null || true)"
fi
[ -n "${VAULT_TOKEN:-}" ] || die "no Vault token: set VAULT_TOKEN or add the Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM"
export VAULT_TOKEN
vault token lookup >/dev/null 2>&1 || die "Vault token invalid / Vault unreachable."

step "Compiling the binary"
# ⚠ NAME THE TARGET. `bun build --compile` builds for the machine it runs on, and a Mac
# build is Mach-O arm64 (PET-521). The argument is appended to the package's build script.
( cd "$SRC" && bun install --frozen-lockfile >/dev/null && bun run build --target=bun-linux-x64 )
[ -x "$SRC/dist/petedio-search" ] || die "bun run build produced no dist/petedio-search."
file -b "$SRC/dist/petedio-search" | grep -q '^ELF 64-bit.*x86-64' \
  || die "dist/petedio-search is not a Linux x86-64 binary: $(file -b "$SRC/dist/petedio-search")"
ls -lh "$SRC/dist/petedio-search"

step "Reading $SECRET_PATH and $APP_PATH"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
umask 077
vault kv get -format=json "$SECRET_PATH" >"$TMP/search.json"
vault kv get -format=json "$APP_PATH" >"$TMP/app.json"
python3 -c '
import json, sys, yaml
d = json.load(open(sys.argv[2]))["data"]["data"]
app = json.load(open(sys.argv[3]))["data"]["data"]
missing = [f for f in ("app_id", "installation_id", "app_pem") if not app.get(f)]
if missing:
    sys.exit("kv/services/claude-workspace-mirror lacks " + ", ".join(missing) + ": run scripts/seed-workspace-mirror-vault.sh.")
callers = {k[len("token_"):]: v for k, v in d.items() if k.startswith("token_") and v}
if not callers:
    sys.exit("kv/services/search has no token_<name> field: run scripts/search-secrets.sh create claude.")
if not d.get("plane_api_key"):
    print("  no plane_api_key: the service indexes the vault and the digest, and skips Plane.")
yaml.safe_dump({
    "search_github_app_id": app["app_id"],
    "search_github_app_installation_id": app["installation_id"],
    "search_github_app_pem": app["app_pem"],
    "search_caller_tokens": callers,
    "search_plane_api_key": d.get("plane_api_key", ""),
}, open(sys.argv[1], "w"))
print("  callers: " + ", ".join(sorted(callers)))
' "$TMP/extra.yml" "$TMP/search.json" "$TMP/app.json"
rm -f "$TMP/search.json" "$TMP/app.json"

step "Running configure-search.yml"
cd "$REPO_ROOT/ansible"
ansible-playbook playbooks/configure-search.yml \
  -e search_binary_src="$SRC/dist/petedio-search" \
  -e "@$TMP/extra.yml" \
  "$@"
