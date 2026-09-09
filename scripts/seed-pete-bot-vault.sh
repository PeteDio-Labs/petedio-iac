#!/usr/bin/env bash
# seed-pete-bot-vault.sh — (re)seed kv/services/pete-bot with the Discord app's
# credentials and the bearer token Uptime Kuma presents to POST /v1/alert (PET-375).
#
# ⚠ WHY A SCRIPT AND NOT TERRAFORM. Rule 6 asks whether the language can already say
# this. It cannot: the Discord token and application id are minted by hand in Discord's
# Developer Portal and exist nowhere a provider can read them. A vault_kv_secret_v2
# resource would also write them in plaintext into the MinIO-backed state, which is
# worse than not declaring them. Writing kv/services/* needs a privileged token anyway —
# the read-only AppRoles cannot write here — so this resolves the Vault token the way
# every sibling reseed script does: $VAULT_TOKEN, else the macOS Keychain item, else a
# prompt.
#
# ⚠ mtrace's API token is deliberately NOT copied here. It already lives at
# kv/services/media/dashboard, and duplicating it would mean rotating it in two places
# and finding out about the second one at 3am. deploy-pete-bot.sh reads both paths.
#
# Usage:
#   ./scripts/seed-pete-bot-vault.sh              # prompts for what it needs
#   ./scripts/seed-pete-bot-vault.sh --rotate     # also mints a fresh alert bearer
set -euo pipefail

ROTATE=0
for arg in "${@:-}"; do
  case "$arg" in
    --rotate) ROTATE=1 ;;
    ""|--) : ;;
    -h|--help) printf 'usage: %s [--rotate]\n' "${0##*/}"; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PATH_KV="kv/services/pete-bot"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$REPO_ROOT/environments/homelab/vault-ca.crt}"

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }

command -v vault >/dev/null || die "vault not in PATH."
command -v python3 >/dev/null || die "python3 not in PATH."

step "Credentials"
if [ -z "${VAULT_TOKEN:-}" ]; then
  VAULT_TOKEN="$(security find-generic-password -s "$VAULT_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null || true)"
fi
if [ -z "${VAULT_TOKEN:-}" ]; then
  # ⚠ A non-TTY run reaches EOF here and `read` returns non-zero, which under `set -e`
  # exits with no message at all. Test for a terminal first so cron says why.
  [ -t 0 ] || die "no VAULT_TOKEN, no Keychain item, and stdin is not a terminal."
  read -rsp "Vault token: " VAULT_TOKEN; echo
fi
export VAULT_TOKEN
vault token lookup >/dev/null 2>&1 || die "Vault token invalid, or Vault is sealed/unreachable."
echo "  vault reachable and token valid"

step "What Discord gives you"
cat <<'NOTE'
  Developer Portal → your application:
    General Information → APPLICATION ID        -> discord_client_id
    Bot → TOKEN (Reset Token to reveal)         -> discord_token
  Discord client → Settings → Advanced → Developer Mode on,
    then right-click your own name → Copy User ID -> owner_user_id
NOTE

EXISTING="$(vault kv get -format=json "$PATH_KV" 2>/dev/null || true)"
have(){ printf '%s' "$EXISTING" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)['data']['data']
except Exception: d={}
print(d.get(sys.argv[1],''))" "$1" 2>/dev/null || true; }

# ⚠ Read secrets with -s so they never echo, and never accept them as arguments —
# argv is world-readable in \`ps\` for the life of the process.
prompt_secret(){ # name, current
  local val
  if [ -n "$2" ]; then
    printf '  %s: already set — press Enter to keep it, or paste a new one: ' "$1" >&2
  else
    printf '  %s: ' "$1" >&2
  fi
  read -rs val; echo >&2
  [ -n "$val" ] && printf '%s' "$val" || printf '%s' "$2"
}
prompt_plain(){ # name, current
  local val
  if [ -n "$2" ]; then
    printf '  %s [%s]: ' "$1" "$2" >&2
  else
    printf '  %s: ' "$1" >&2
  fi
  read -r val
  [ -n "$val" ] && printf '%s' "$val" || printf '%s' "$2"
}

step "Values"
DISCORD_TOKEN="$(prompt_secret discord_token "$(have discord_token)")"
DISCORD_CLIENT_ID="$(prompt_plain discord_client_id "$(have discord_client_id)")"
OWNER_USER_ID="$(prompt_plain owner_user_id "$(have owner_user_id)")"

[ -n "$DISCORD_TOKEN" ]     || die "discord_token is required."
[ -n "$DISCORD_CLIENT_ID" ] || die "discord_client_id is required."
[ -n "$OWNER_USER_ID" ]     || die "owner_user_id is required."

# Snowflakes are 17-20 digits. Catching a pasted username here costs one regex and
# saves a deploy that starts cleanly and then silently answers nobody.
case "$DISCORD_CLIENT_ID" in ''|*[!0-9]*) die "discord_client_id must be all digits (the Application ID, not the name).";; esac
case "$OWNER_USER_ID"     in ''|*[!0-9]*) die "owner_user_id must be all digits — enable Developer Mode, then right-click your name → Copy User ID.";; esac

ALERT_BEARER="$(have alert_bearer_token)"
if [ -z "$ALERT_BEARER" ] || [ "$ROTATE" = "1" ]; then
  ALERT_BEARER="$(python3 -c 'import secrets;print(secrets.token_urlsafe(32))')"
  echo "  alert_bearer_token: minted a fresh one"
else
  echo "  alert_bearer_token: keeping the existing one (--rotate to replace)"
fi

step "Write"
# umask BEFORE the file exists: mktemp -d gives a 0700 parent, but the file inside it
# inherits the process umask and would otherwise land 0644 with the token in it.
umask 077
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# JSON built by a serialiser, not printf: a Discord token contains dots and can contain
# characters that are valid in the value and invalid in a bare shell or YAML scalar.
# Values arrive through the ENVIRONMENT, never argv.
OUT="$TMP/payload.json" \
DISCORD_TOKEN="$DISCORD_TOKEN" \
DISCORD_CLIENT_ID="$DISCORD_CLIENT_ID" \
OWNER_USER_ID="$OWNER_USER_ID" \
ALERT_BEARER="$ALERT_BEARER" \
python3 -c '
import json, os
json.dump({
    "discord_token":      os.environ["DISCORD_TOKEN"],
    "discord_client_id":  os.environ["DISCORD_CLIENT_ID"],
    "owner_user_id":      os.environ["OWNER_USER_ID"],
    "alert_bearer_token": os.environ["ALERT_BEARER"],
}, open(os.environ["OUT"], "w"))
'

vault kv put "$PATH_KV" @"$TMP/payload.json" >/dev/null \
  || die "vault kv put failed for $PATH_KV."

step "Verify — read it back rather than trusting the write"
FIELDS="$(vault kv get -format=json "$PATH_KV" | python3 -c '
import json,sys
d=json.load(sys.stdin)["data"]["data"]
print(",".join(sorted(d)))
print("client_id:", d.get("discord_client_id","?"))
print("owner:", d.get("owner_user_id","?"))
print("token len:", len(d.get("discord_token","")))
print("bearer len:", len(d.get("alert_bearer_token","")))
')"
echo "$FIELDS" | sed 's/^/  /'

step "Done"
cat <<NOTE
  Seeded $PATH_KV.

  The two non-secret values are printed above on purpose — a mistyped user id is the
  failure that looks like a working bot answering nobody.

  Next: deploy pete-bot, then run the DM test that PET-375 exists to settle.
NOTE
