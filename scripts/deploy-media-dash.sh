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
[ -n "${VAULT_TOKEN:-}" ] || die "no Vault token: set VAULT_TOKEN or add the Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM"
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
missing = [k for k in ("ssh_private_key", "ssh_public_key") if not d.get(k)]
if missing:
    sys.exit("kv/services/media/dashboard is missing: " + ", ".join(missing) +
             " — run scripts/reseed-media-dash-vault.sh first.")

# One token per caller (PET-518): every token_<name> field maps to caller <name>. The
# legacy api_token maps to "pete-bot", unless token_pete-bot already exists — once
# scripts/mtrace-caller-token.sh mints a dedicated token, that one wins.
caller_tokens = {}
for key, value in d.items():
    if key.startswith("token_") and value:
        caller_tokens[key[len("token_"):]] = value
if d.get("api_token") and "pete-bot" not in caller_tokens:
    caller_tokens["pete-bot"] = d["api_token"]

if not caller_tokens:
    sys.exit("kv/services/media/dashboard has no caller tokens (token_<name> fields, or "
             "the legacy api_token) — run scripts/mtrace-caller-token.sh create <name>.")

yaml.safe_dump({
    "media_dash_ssh_private_key": d["ssh_private_key"],
    "media_dash_ssh_public_key": d["ssh_public_key"],
    "mtrace_caller_tokens": caller_tokens,
}, open(sys.argv[1], "w"))
' "$TMP/extra.yml"

step "Running configure-media-dash.yml"
cd "$REPO_ROOT/ansible"
ansible-playbook playbooks/configure-media-dash.yml \
  -e media_dash_binary_src="$SRC/dist/mtrace" \
  -e "@$TMP/extra.yml" \
  "$@"

step "Confirming the LAN bind refuses this controller"
# ⚠ THE MAC IS NOT IN mtrace_allow_sources. Only pete-pi-1 (192.168.50.4, the tailnet
# subnet router) is allowed, so a successful TCP connect from here means the allowlist
# did not load, not that everything is fine. The one exception: a controller that itself
# reaches the LAN through pete-pi-1 (for example, over the tailnet with pete-pi-1 as the
# subnet router) — that controller SHOULD see this "probe succeeded" failure, because it
# is indistinguishable on the wire from .4 itself.
#
# Portable background-and-kill instead of `timeout`: macOS's default bash ships with no
# timeout(1), but /dev/tcp is a bash builtin on both platforms.
mtrace_probe_open() {
  local host="$1" port="$2" secs="$3"
  ( exec 3<>"/dev/tcp/${host}/${port}" ) >/dev/null 2>&1 &
  local probe_pid=$!
  ( sleep "$secs"; kill -KILL "$probe_pid" >/dev/null 2>&1 ) &
  local killer_pid=$!
  local rc=0
  wait "$probe_pid" 2>/dev/null || rc=$?
  kill "$killer_pid" >/dev/null 2>&1 || true
  wait "$killer_pid" 2>/dev/null || true
  return "$rc"
}

if mtrace_probe_open 192.168.50.237 8237 5; then
  die "192.168.50.237:8237 accepted a TCP connection from this controller. Either the" \
      "allowlist did not load, or this controller reaches the LAN through pete-pi-1" \
      "(192.168.50.4) — the one caller mtrace_allow_sources permits."
fi
echo "  refused, as expected from a controller outside mtrace_allow_sources"
