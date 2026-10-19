#!/usr/bin/env bash
# deploy-pete-bot.sh — build pete-bot and install it on media-dash-237 (PET-375).
#
# ⚠ WHY A SCRIPT. Rule 6: the play is the declaration, and this only carries the two
# things it cannot. The binary is compiled from a sibling clone that Terraform and
# Ansible have no view of, and the secrets live in Vault behind a privileged read that
# a play cannot perform for itself.
#
# ⚠ ONE VAULT PATH. Every credential pete-bot uses is at kv/services/pete-bot. It no
# longer reads kv/services/media/dashboard, because it no longer calls mtrace (PET-518).
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
# The Vault token comes from $VAULT_TOKEN, else the macOS Keychain. The script never
# prompts for it, so a paste never lands in a terminal's scrollback.
if [ -z "${VAULT_TOKEN:-}" ] && command -v security >/dev/null; then
  VAULT_TOKEN="$(security find-generic-password -s "$VAULT_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null || true)"
fi
[ -n "${VAULT_TOKEN:-}" ] \
  || die "no VAULT_TOKEN and no Keychain item '$VAULT_TOKEN_KEYCHAIN_ITEM'. Export VAULT_TOKEN, then run this again."
export VAULT_TOKEN
vault token lookup >/dev/null 2>&1 \
  || die "the Vault token is invalid, or Vault is sealed. Run scripts/pet-secrets doctor."

# ⚠ ONE READ OF THE WHOLE PATH. A per-field `vault kv get ... || true` turns a 403, a
# timeout or a sealed Vault into "this optional field is absent", and the deploy then
# ships the bot with that feature quietly off. A failed read stops here instead, and an
# optional field is empty only when the path really lacks it.
SNAPSHOT="$(vault kv get -format=json kv/services/pete-bot 2>/dev/null)" \
  || die "cannot read kv/services/pete-bot. Run scripts/pet-secrets doctor."
# field NAME prints one field of $SNAPSHOT. The value reaches python through the
# environment, never argv, and returns into a variable.
field(){ SNAPSHOT="$SNAPSHOT" python3 -c '
import json, os, sys
print((json.loads(os.environ["SNAPSHOT"])["data"]["data"] or {}).get(sys.argv[1], ""))' "$1"; }
need(){ local v; v="$(field "$1")"; [ -n "$v" ] || die "kv/services/pete-bot has no field '$1'."; printf '%s' "$v"; }
PB_TOKEN="$(need discord_token)"
PB_CLIENT="$(need discord_client_id)"
PB_OWNER="$(need owner_user_id)"
PB_BEARER="$(need alert_bearer_token)"
# Required (PET-584): the bearer notify-pedro sends to /v1/notify. To mint it, run
# scripts/seed-pete-bot-notify-token.sh.
PB_NOTIFY_BEARER="$(need notify_bearer_token)"
# Optional (PET-395): the token /update dispatches with. Absent leaves /update saying it
# is not configured, rather than failing the whole deploy.
PB_UPDATES_TOKEN="$(field github_updates_token)"
# Optional (PET-645): the merge desk's App. All three, or the desk stays off. To seed them,
# run scripts/seed-pete-bot-desk-app.sh.
PB_DESK_APP_ID="$(field desk_app_id)"
PB_DESK_INSTALLATION_ID="$(field desk_installation_id)"
PB_DESK_APP_PEM="$(field desk_app_pem)"
# Optional (PET-617), together or not at all: the gateway's Anthropic key and lab-map's
# bearer. Absent leaves the gateway off. scripts/seed-llm-gateway.sh writes both, and the
# play refuses one without the other.
PB_ANTHROPIC_KEY="$(field anthropic_api_key)"
PB_GATEWAY_LAB_MAP="$(field gateway_token_lab_map)"
unset SNAPSHOT
echo "  resolved the 5 required values"
if [ -n "$PB_DESK_APP_ID" ] && [ -n "$PB_DESK_INSTALLATION_ID" ] && [ -n "$PB_DESK_APP_PEM" ]; then
  echo "  merge desk: App present"
else
  echo "  merge desk: the App is not seeded, so the desk stays off"
fi
if [ -n "$PB_UPDATES_TOKEN" ]; then
  echo "  /update: token present"
else
  echo "  /update: no github_updates_token, so /update will say it is not configured"
fi
if [ -n "$PB_ANTHROPIC_KEY" ]; then
  echo "  gateway: key present, so the play requires llm: on"
else
  echo "  gateway: no anthropic_api_key, so the gateway stays off"
fi

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
PB_BEARER="$PB_BEARER" PB_NOTIFY_BEARER="$PB_NOTIFY_BEARER" BIN="$BIN" \
PB_UPDATES_TOKEN="$PB_UPDATES_TOKEN" \
PB_ANTHROPIC_KEY="$PB_ANTHROPIC_KEY" PB_GATEWAY_LAB_MAP="$PB_GATEWAY_LAB_MAP" \
PB_DESK_APP_ID="$PB_DESK_APP_ID" PB_DESK_INSTALLATION_ID="$PB_DESK_INSTALLATION_ID" \
PB_DESK_APP_PEM="$PB_DESK_APP_PEM" \
python3 -c '
import json, os
json.dump({
    "pete_bot_binary_src":       os.environ["BIN"],
    "pete_bot_discord_token":    os.environ["PB_TOKEN"],
    "pete_bot_discord_client_id":os.environ["PB_CLIENT"],
    "pete_bot_owner_user_id":    os.environ["PB_OWNER"],
    "pete_bot_alert_bearer":     os.environ["PB_BEARER"],
    "pete_bot_notify_bearer":    os.environ["PB_NOTIFY_BEARER"],
    "pete_bot_github_updates_token": os.environ.get("PB_UPDATES_TOKEN", ""),
    "pete_bot_anthropic_api_key": os.environ.get("PB_ANTHROPIC_KEY", ""),
    "pete_bot_gateway_token_lab_map": os.environ.get("PB_GATEWAY_LAB_MAP", ""),
    "pete_bot_desk_app_id":          os.environ.get("PB_DESK_APP_ID", ""),
    "pete_bot_desk_installation_id": os.environ.get("PB_DESK_INSTALLATION_ID", ""),
    "pete_bot_desk_app_pem":         os.environ.get("PB_DESK_APP_PEM", ""),
}, open(os.environ["OUT"], "w"))
'

cd "$ANSIBLE_DIR"
ansible-playbook -i inventory/ playbooks/configure-pete-bot.yml -e "@$TMP/extra.json" "${ANSIBLE_ARGS[@]+"${ANSIBLE_ARGS[@]}"}"

step "Done"
cat <<'NOTE'
  pete-bot is on media-dash-237. It reaches Discord and GitHub outbound, and nothing
  new listens on the LAN.

  Check it with:
    ssh root@192.168.50.10 'pct exec 237 -- systemctl status pete-bot --no-pager'
NOTE
