#!/usr/bin/env bash
# seed-authentik-api-token.sh — mint an Authentik API token and write it to Vault (PET-946).
#
# WHY. scripts/seed-vault-oidc.sh calls Authentik's API. The bootstrap_token at
# kv/services/authentik answers `403 Token invalid/expired`, so the seed has no working
# credential. This script mints one that works and stores it where the seed reads it:
#   kv/services/authentik-api, key api_token
# It does not use kv/services/authentik: the claude-ops policy reads that path, and an Authentik
# admin token must not reach it.
#
# HOW. Authentik's own shell mints the token, so no existing token is needed. The script SSHes to
# pve03, runs `docker compose exec server ak shell -c <code>` in LXC 119 through `pct exec`, and
# reads one marker line from stdout. The code carries no secret. The token key travels back on
# stdout only: it is never an argument on any hop and never printed. It then goes to Vault on
# stdin, and the script reads it back from Vault and proves it against the Authentik API.
#
# The token belongs to $AUTHENTIK_USER (default akadmin), has intent `api`, and does not expire.
# Each run deletes the token with the same identifier and mints a new one, so a re-run rotates it.
#
#   Vault token: $VAULT_TOKEN, else macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM. No prompt.
#   SSH:         $PVE_SSH_KEY (default ~/.ssh/id_ed25519_proxmox_pedro), root@pve03
#   Authentik:   $AUTHENTIK_URL (default https://auth.pdlab.dev), $AUTHENTIK_USER (default akadmin)
#
# Bash 3.2 compatible (the Mac's /bin/bash): the Python lives in a function, never in a heredoc
# inside $( ). Checked by .github/workflows/bash32.yml.
#
# Usage:
#   ./scripts/seed-authentik-api-token.sh
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"
AUTHENTIK_URL="${AUTHENTIK_URL:-https://auth.pdlab.dev}"
AUTHENTIK_USER="${AUTHENTIK_USER:-akadmin}"
VAULT_PATH="kv/services/authentik-api"
TOKEN_ID="vault-oidc-seed"

PVE03="root@192.168.50.10"
PVE_SSH_KEY="${PVE_SSH_KEY:-$HOME/.ssh/id_ed25519_proxmox_pedro}"
pve03() { ssh -o ConnectTimeout=8 -o IdentitiesOnly=yes -i "$PVE_SSH_KEY" "$PVE03" "$@"; }
CT=119
COMPOSE=/opt/authentik/docker-compose.yml

die()  { printf '\033[31mERROR\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

for t in vault ssh curl base64; do command -v "$t" >/dev/null || die "$t not in PATH"; done
[ -f "$PVE_SSH_KEY" ] || die "No SSH key at $PVE_SSH_KEY. Set PVE_SSH_KEY to the key root@pve03 accepts."
case "$AUTHENTIK_USER" in
  *[!A-Za-z0-9_.-]*|"") die "AUTHENTIK_USER must be letters, digits, dot, dash or underscore." ;;
esac

# The code ak shell runs. It holds no secret. Failure raises, which makes ak shell exit non-zero.
mint_code() {
cat <<'PY'
import os
from authentik.core.models import Token, TokenIntents, User
user = User.objects.get(username=os.environ["AK_MINT_USER"])
Token.objects.filter(identifier=os.environ["AK_MINT_ID"]).delete()
token = Token.objects.create(
    identifier=os.environ["AK_MINT_ID"],
    intent=TokenIntents.INTENT_API,
    user=user,
    expiring=False,
    description="Vault OIDC seed (PET-946). Minted by scripts/seed-authentik-api-token.sh.",
)
print("MINTED_TOKEN_KEY=" + token.key)
PY
}

step "Authenticating to Vault"
[ -f "$VAULT_CACERT" ] || die "VAULT_CACERT not found at '$VAULT_CACERT'. Run this from inside the repo, or export VAULT_CACERT."
if [ -z "${VAULT_TOKEN:-}" ]; then
  VAULT_TOKEN="$(security find-generic-password -s "$VAULT_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null || true)"
fi
[ -n "${VAULT_TOKEN:-}" ] || die "no Vault token: set VAULT_TOKEN or add the Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM. This script does not prompt."
export VAULT_TOKEN
vault token lookup >/dev/null 2>&1 || die "Vault rejected the token, or $VAULT_ADDR is unreachable."

step "Checking Authentik runs in LXC $CT before minting"
SERVER_ID="$(pve03 "pct exec $CT -- docker compose -f $COMPOSE ps -q server" </dev/null)" \
  || die "could not list containers in LXC $CT through pve03. Nothing was minted."
[ -n "$SERVER_ID" ] || die "no running 'server' container in LXC $CT. Nothing was minted."

step "Minting the token in Authentik (the key is not printed)"
# The code goes over as base64: only A-Z a-z 0-9 + / = reach the remote shell, so one level of
# single quotes is safe. pct exec passes the arguments on without a second shell.
# The two -e values (user name and token identifier) are not secrets.
CODE_B64="$(mint_code | base64 | tr -d '\n')"
[ -n "$CODE_B64" ] || die "could not encode the mint code."
EXEC_PY="exec(__import__(\"base64\").b64decode(\"$CODE_B64\").decode())"
MINT_OUT="$(pve03 "pct exec $CT -- docker compose -f $COMPOSE exec -T -e AK_MINT_USER='$AUTHENTIK_USER' -e AK_MINT_ID='$TOKEN_ID' server ak shell -c '$EXEC_PY'" </dev/null)" \
  || die "ak shell failed. Nothing was written to Vault. The user '$AUTHENTIK_USER' must exist in Authentik."
TOKEN_KEY="$(printf '%s\n' "$MINT_OUT" | sed -n 's/^MINTED_TOKEN_KEY=//p' | head -n 1)"
unset MINT_OUT
[ -n "$TOKEN_KEY" ] || die "ak shell ran but printed no token key. Nothing was written to Vault."

step "Writing $VAULT_PATH (api_token)"
# kv put replaces the whole secret; this path holds only api_token and owner, so nothing is lost.
printf '%s' "$TOKEN_KEY" | vault kv put "$VAULT_PATH" api_token=- authentik_user="$AUTHENTIK_USER" token_identifier="$TOKEN_ID" >/dev/null \
  || die "vault kv put failed. The token exists in Authentik; a re-run deletes it and mints another."
unset TOKEN_KEY

step "Proving the stored token against the Authentik API"
STORED="$(vault kv get -field=api_token "$VAULT_PATH")"
[ -n "$STORED" ] || die "Vault returned an empty api_token after the write."
# The header goes in through curl's config on stdin, so the token is not in a process list.
# A named agent: Cloudflare blocks the default Python and some curl agents with error 1010.
CODE="$(printf 'header = "Authorization: Bearer %s"\n' "$STORED" | curl -sS --config - -m 30 \
  -A "petedio-seed-authentik-api-token" -o /dev/null -w '%{http_code}' "$AUTHENTIK_URL/api/v3/admin/version/")" \
  || die "could not reach $AUTHENTIK_URL."
unset STORED
case "$CODE" in
  200) printf 'Authentik accepted the stored token: HTTP 200 on /api/v3/admin/version/.\n' ;;
  401|403) die "Authentik answered HTTP $CODE to the token it just minted. The key in Vault is not usable." ;;
  *) die "unexpected HTTP $CODE from $AUTHENTIK_URL; the token was not proven." ;;
esac

printf '\n\033[32mSeeded %s (api_token, user %s). No secret was printed.\033[0m\n' "$VAULT_PATH" "$AUTHENTIK_USER"
printf 'Next: ./scripts/seed-vault-oidc.sh\n'
