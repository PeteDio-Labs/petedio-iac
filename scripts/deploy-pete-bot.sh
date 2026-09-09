#!/usr/bin/env bash
# deploy-pete-bot.sh — build pete-bot and install it on media-dash-237 (PET-375).
#
# ⚠ WHY A SCRIPT. Rule 6: the play is the declaration, and this only carries the two
# things it cannot. The binary is compiled from a sibling clone that Terraform and
# Ansible have no view of, and the secrets live in Vault behind a privileged read that
# a play cannot perform for itself.
#
# ⚠ TWO VAULT PATHS, DELIBERATELY. pete-bot's own credentials are at
# kv/services/pete-bot; mtrace's API token stays at kv/services/media/dashboard and is
# read from there rather than copied. Duplicating it would mean rotating it in two
# places and finding out about the second one at 3am.
#
# Usage:
#   ./scripts/deploy-pete-bot.sh              # build, then deploy
#   ./scripts/deploy-pete-bot.sh --check      # ansible dry run
#   ./scripts/deploy-pete-bot.sh --no-build   # deploy the binary already in dist/
set -euo pipefail

BUILD=1
ANSIBLE_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --no-build) BUILD=0 ;;
    --check) ANSIBLE_ARGS+=(--check) ;;
    -h|--help) printf 'usage: %s [--check] [--no-build]\n' "${0##*/}"; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ANSIBLE_DIR="$REPO_ROOT/ansible"
SRC="${PETE_BOT_SRC:-$REPO_ROOT/../pete-bot}"
BIN="$SRC/dist/pete-bot"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$REPO_ROOT/environments/homelab/vault-ca.crt}"

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }

for t in vault ansible-playbook python3; do command -v "$t" >/dev/null || die "$t not in PATH."; done
[ -d "$SRC" ] || die "pete-bot clone not found at $SRC (set PETE_BOT_SRC)."
# ⚠ Check bun only when we intend to build. --no-build exists so a machine without bun
# can still deploy an artifact someone else compiled.
[ "$BUILD" = "1" ] && { command -v bun >/dev/null || die "bun not in PATH (or pass --no-build)."; }

step "Credentials"
if [ -z "${VAULT_TOKEN:-}" ]; then
  VAULT_TOKEN="$(security find-generic-password -s "$VAULT_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null || true)"
fi
if [ -z "${VAULT_TOKEN:-}" ]; then
  [ -t 0 ] || die "no VAULT_TOKEN, no Keychain item, and stdin is not a terminal."
  read -rsp "Vault token: " VAULT_TOKEN; echo
fi
export VAULT_TOKEN
vault token lookup >/dev/null 2>&1 || die "Vault token invalid, or Vault is sealed/unreachable."

read_field(){ vault kv get -field="$2" "$1" 2>/dev/null || die "cannot read $1 field '$2'."; }
PB_TOKEN="$(read_field kv/services/pete-bot discord_token)"
PB_CLIENT="$(read_field kv/services/pete-bot discord_client_id)"
PB_OWNER="$(read_field kv/services/pete-bot owner_user_id)"
PB_BEARER="$(read_field kv/services/pete-bot alert_bearer_token)"
MTRACE_TOKEN="$(read_field kv/services/media/dashboard api_token)"
echo "  resolved 5 values from 2 paths"

if [ "$BUILD" = "1" ]; then
  step "Build the standalone binary"
  # 237 has neither node nor bun and 512 MB of RAM, so it gets one file and owns no
  # runtime. linux-x64 explicitly: this builds on an arm64 Mac and an x64 runner, and
  # the target is amd64 either way. An arm64 binary installs cleanly and never executes.
  ( cd "$SRC" && bun install --frozen-lockfile >/dev/null && bun run build:binary >/dev/null )
  [ -x "$BIN" ] || die "build produced no $BIN."
  file "$BIN" | grep -qi 'x86-64\|x86_64' || die "built binary is not x86-64 — check the --target."
  printf '  %s (%s)\n' "$BIN" "$(du -h "$BIN" | cut -f1)"
else
  [ -x "$BIN" ] || die "--no-build given but no binary at $BIN."
fi

step "Deploy to media-dash-237"
umask 077
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# JSON, not YAML: a Discord token carries dots and a base64 bearer can begin with a
# quote or contain a colon. Both are valid values and invalid bare YAML scalars. Values
# reach python through the ENVIRONMENT, never argv.
OUT="$TMP/extra.json" \
PB_TOKEN="$PB_TOKEN" PB_CLIENT="$PB_CLIENT" PB_OWNER="$PB_OWNER" \
PB_BEARER="$PB_BEARER" MTRACE_TOKEN="$MTRACE_TOKEN" BIN="$BIN" \
python3 -c '
import json, os
json.dump({
    "pete_bot_binary_src":       os.environ["BIN"],
    "pete_bot_discord_token":    os.environ["PB_TOKEN"],
    "pete_bot_discord_client_id":os.environ["PB_CLIENT"],
    "pete_bot_owner_user_id":    os.environ["PB_OWNER"],
    "pete_bot_alert_bearer":     os.environ["PB_BEARER"],
    "pete_bot_mtrace_token":     os.environ["MTRACE_TOKEN"],
}, open(os.environ["OUT"], "w"))
'

cd "$ANSIBLE_DIR"
ansible-playbook -i inventory/ playbooks/configure-pete-bot.yml -e "@$TMP/extra.json" "${ANSIBLE_ARGS[@]+"${ANSIBLE_ARGS[@]}"}"

step "Done"
cat <<'NOTE'
  pete-bot is on media-dash-237. It reaches mtrace over loopback and Discord outbound;
  nothing new listens on the LAN.

  Check it with:
    ssh root@192.168.50.10 'pct exec 237 -- systemctl status pete-bot --no-pager'
NOTE
