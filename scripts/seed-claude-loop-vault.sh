#!/usr/bin/env bash
# seed-claude-loop-vault.sh — put the petedio-claude-loop GitHub App credentials into Vault
# at kv/services/claude-loop, for the unattended work loop on claude-247 (PET-399).
#
# WHY A SCRIPT AND NOT A PASTE. The private key is multi-line, and a PEM that loses its
# newlines still LOOKS like a key: `vault kv put app_pem=@file` and a copy-paste through a
# terminal both produce something that stores fine and fails later, at which point openssl
# complains about the signature rather than the field. So the newlines are checked here,
# before the value is written, where the error can name the real cause.
#
# WHAT THIS DOES NOT DO. It does not create the App, generate the key, or install it —
# those are browser steps. It does not deploy anything to 247; that is
# scripts/deploy-claude-loop.sh, which reads this path.
#
#   Vault token: $VAULT_TOKEN, else macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM, else prompt
#
# The key is never printed, never passed in argv, and never leaves this process except into
# Vault over TLS. Verification reads properties back, never the value.
#
# Usage:
#   ./scripts/seed-claude-loop-vault.sh ~/Downloads/petedio-claude-loop.*.private-key.pem
#   ./scripts/seed-claude-loop-vault.sh --shred <pem>     # overwrite + delete the file after
#   APP_ID=... INSTALLATION_ID=... ./scripts/seed-claude-loop-vault.sh <pem>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"
VAULT_PATH="kv/services/claude-loop"
ORG="PeteDio-Labs"
REPO="petedio-iac"
APP_SLUG="petedio-claude-loop"

die()  { printf '\033[31mERROR\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

SHRED=0
PEM_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --shred) SHRED=1 ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) PEM_FILE="$1" ;;
  esac
  shift
done

# ---------------------------------------------------------------- the key file
[ -n "$PEM_FILE" ] || die "Pass the .pem downloaded from the App settings page. See --help."
[ -f "$PEM_FILE" ] || die "No such file: $PEM_FILE"

step "Checking the private key"
# ⚠ THE CHECK THIS SCRIPT EXISTS FOR. A one-line PEM stores happily and fails at signing
# time with an error that points at the JWT, not at the field.
LINES="$(wc -l < "$PEM_FILE" | tr -d ' ')"
[ "$LINES" -ge 3 ] || die "This PEM is $LINES line(s) — its newlines are gone. Re-download it; do not retype it."
grep -q -- "-----BEGIN" "$PEM_FILE" || die "No PEM header found in $PEM_FILE."
# Prove it is a usable key rather than merely PEM-shaped. Prints "RSA key ok", not the key.
openssl rsa -in "$PEM_FILE" -noout -check >/dev/null 2>&1 \
  || openssl pkey -in "$PEM_FILE" -noout -check >/dev/null 2>&1 \
  || die "openssl cannot parse $PEM_FILE as a private key."
echo "  $LINES lines, header present, openssl parses it."

# ------------------------------------------------------------------- the ids
step "Resolving app_id and installation_id"
APP_ID="${APP_ID:-}"
INSTALLATION_ID="${INSTALLATION_ID:-}"

if [ -z "$APP_ID" ] || [ -z "$INSTALLATION_ID" ]; then
  command -v gh >/dev/null 2>&1 || die "gh not found — set APP_ID and INSTALLATION_ID explicitly."
  # Discover from the org's installations. Needs only a user token; the repo-level
  # /installation endpoint wants an App JWT and 401s here, which is expected, not a fault.
  INST_JSON="$(gh api "/orgs/$ORG/installations" \
      --jq ".installations[] | select(.app_slug==\"$APP_SLUG\") | {app_id, id}" 2>/dev/null || true)"
  [ -n "$INST_JSON" ] || die "No installation of '$APP_SLUG' found on $ORG. Install it on $REPO first (App settings -> Install App)."
  APP_ID="${APP_ID:-$(printf '%s' "$INST_JSON" | sed -n 's/.*"app_id":[[:space:]]*\([0-9]*\).*/\1/p')}"
  INSTALLATION_ID="${INSTALLATION_ID:-$(printf '%s' "$INST_JSON" | sed -n 's/.*"id":[[:space:]]*\([0-9]*\).*/\1/p')}"
fi

case "$APP_ID" in ''|*[!0-9]*) die "app_id is not numeric: '$APP_ID'" ;; esac
case "$INSTALLATION_ID" in ''|*[!0-9]*) die "installation_id is not numeric: '$INSTALLATION_ID'" ;; esac
echo "  app_id=$APP_ID  installation_id=$INSTALLATION_ID"

# ------------------------------------------------------------------- vault
step "Authenticating to Vault"
# ⚠ CHECK THE CA BUNDLE BEFORE BLAMING THE NETWORK. `vault` reports a missing VAULT_CACERT
# as an unreachable server, which sends you to look at .223 when the real fault is a path.
# It happens when this script is copied somewhere else and run from there: REPO_ROOT is
# derived from the script's own location, so from /tmp it resolves to / and the cert is
# sought at //environments/homelab/vault-ca.crt. Run it from the repo, or set VAULT_CACERT.
[ -f "$VAULT_CACERT" ] || die "VAULT_CACERT not found at '$VAULT_CACERT'.
  This is almost always a path problem, not a Vault problem — run the script from inside the
  repo (./scripts/seed-claude-loop-vault.sh), or export VAULT_CACERT explicitly."
if [ -z "${VAULT_TOKEN:-}" ]; then
  VAULT_TOKEN="$(security find-generic-password -s "$VAULT_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null || true)"
fi
[ -n "${VAULT_TOKEN:-}" ] || { read -rsp "Vault token: " VAULT_TOKEN; echo; }
export VAULT_TOKEN
vault token lookup >/dev/null 2>&1 || die "Vault rejected the token, or $VAULT_ADDR is unreachable.
  Check both before assuming either: ./scripts/pet-secrets doctor reports whether Vault is
  sealed and whether the Keychain still holds the bootstrap chain."

step "Writing $VAULT_PATH"
command -v jq >/dev/null 2>&1 || die "jq is required (it is what preserves the newlines)."
# --rawfile slurps the key as one JSON string with its newlines intact, and stdin keeps it
# out of argv, where `ps` would show it.
jq -n --rawfile pem "$PEM_FILE" --arg app_id "$APP_ID" --arg installation_id "$INSTALLATION_ID" \
  '{app_id: $app_id, installation_id: $installation_id, app_pem: $pem}' \
  | vault kv put "$VAULT_PATH" - >/dev/null

step "Verifying by read-back (never printing the key)"
[ "$(vault kv get -field=app_id "$VAULT_PATH")" = "$APP_ID" ] || die "app_id read-back mismatch."
[ "$(vault kv get -field=installation_id "$VAULT_PATH")" = "$INSTALLATION_ID" ] || die "installation_id read-back mismatch."
BACK_LINES="$(vault kv get -field=app_pem "$VAULT_PATH" | wc -l | tr -d ' ')"
[ "$BACK_LINES" -ge 3 ] || die "app_pem came back as $BACK_LINES line(s) — the newlines did not survive."
vault kv get -field=app_pem "$VAULT_PATH" | { openssl rsa -noout -check >/dev/null 2>&1 || openssl pkey -noout -check >/dev/null 2>&1; } \
  || die "app_pem read back from Vault does not parse as a key."
echo "  app_id, installation_id and a $BACK_LINES-line key that openssl still accepts."

# ------------------------------------------------------------------- cleanup
if [ "$SHRED" -eq 1 ]; then
  step "Removing the downloaded key"
  rm -P "$PEM_FILE" 2>/dev/null || rm -f "$PEM_FILE"
  echo "  $PEM_FILE removed."
else
  step "⚠ The downloaded key is still on disk"
  echo "  $PEM_FILE"
  echo "  It carries contents:write on $REPO. Delete it, or re-run with --shred."
fi

step "Next"
cat <<TXT
  1. Confirm the App is installed on $REPO ONLY (App settings -> Install App).
  2. On claude-247: ./scripts/deploy-claude-loop.sh   # reads $VAULT_PATH, lands the key root-owned
  3. The loop timer stays OFF until it is enabled deliberately — see PET-399.
TXT
