#!/usr/bin/env bash
# seed-forgejo-mirror-vault.sh — put the petedio-forgejo-mirror GitHub App credentials into Vault
# at kv/services/forgejo-mirror, so forgejo-249 can copy every PeteDio-Labs repo (PET-756).
#
# WHY A NEW APP. The workspace-mirror App reaches five named repositories and the org refuses
# deploy keys. This App is the mirror's own, installed on ALL repositories of PeteDio-Labs so a
# new repo is mirrored without a settings change, and it holds nothing but read access.
#
# Create it once, in the browser (github.com/organizations/PeteDio-Labs/settings/apps/new):
#   name                       petedio-forgejo-mirror
#   Webhook                    off
#   Repository permissions     Contents: Read-only   Metadata: Read-only   (nothing else)
#   Where can it be installed  Only on this account
# Then generate a private key, and install the App on the org with "All repositories".
#
# ⚠ THE SCOPE IS THE SECURITY ARGUMENT. This script proves it against GitHub before it writes:
# the permissions are exactly contents=read,metadata=read, the install is "all", and a token
# minted from the key carries the same permissions and reaches at least one repository. An App
# with write access is caught here, not after a root timer has used it.
#
# It does not create or install the App. It deploys nothing: scripts/deploy-forgejo-mirror.sh
# reads this path. The key is never printed or passed in argv.
#
#   Vault token: $VAULT_TOKEN, else macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM. Never prompts.
#
# Usage:
#   ./scripts/seed-forgejo-mirror-vault.sh ~/Downloads/petedio-forgejo-mirror.*.private-key.pem
#   ./scripts/seed-forgejo-mirror-vault.sh --shred <pem>   # overwrite + delete the file after
#   APP_ID=... INSTALLATION_ID=... ./scripts/seed-forgejo-mirror-vault.sh <pem>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"
VAULT_PATH="kv/services/forgejo-mirror"
ORG="PeteDio-Labs"
APP_SLUG="petedio-forgejo-mirror"
# Sorted "key=value" pairs, comma-joined, as GitHub reports them. Anything else fails.
WANT_PERMS="contents=read,metadata=read"

die()  { printf '\033[31mERROR\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

SHRED=0
PEM_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --shred) SHRED=1 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) PEM_FILE="$1" ;;
  esac
  shift
done

[ -n "$PEM_FILE" ] || die "Pass the .pem downloaded from the App settings page. See --help."
[ -f "$PEM_FILE" ] || die "No such file: $PEM_FILE"
for t in vault openssl curl jq; do command -v "$t" >/dev/null || die "$t not in PATH"; done

step "Checking the private key"
# A one-line PEM stores happily and fails at signing time with an error that points at the JWT.
LINES="$(wc -l < "$PEM_FILE" | tr -d ' ')"
[ "$LINES" -ge 3 ] || die "This PEM is $LINES line(s): its newlines are gone. Re-download it; do not retype it."
grep -q -- "-----BEGIN" "$PEM_FILE" || die "No PEM header found in $PEM_FILE."
openssl rsa -in "$PEM_FILE" -noout -check >/dev/null 2>&1 \
  || openssl pkey -in "$PEM_FILE" -noout -check >/dev/null 2>&1 \
  || die "openssl cannot parse $PEM_FILE as a private key."
echo "  $LINES lines, header present, openssl parses it."

step "Resolving app_id and installation_id"
APP_ID="${APP_ID:-}"
INSTALLATION_ID="${INSTALLATION_ID:-}"
INST_JSON=""
if command -v gh >/dev/null 2>&1; then
  INST_JSON="$(gh api "/orgs/$ORG/installations" \
      --jq ".installations[] | select(.app_slug==\"$APP_SLUG\")" 2>/dev/null || true)"
fi
[ -n "$INST_JSON" ] || [ -n "$APP_ID$INSTALLATION_ID" ] \
  || die "No installation of '$APP_SLUG' found on $ORG, and gh could not be asked.
  Create and install the App first (see --help), or set APP_ID and INSTALLATION_ID."

if [ -n "$INST_JSON" ]; then
  APP_ID="${APP_ID:-$(printf '%s' "$INST_JSON" | jq -r '.app_id')}"
  INSTALLATION_ID="${INSTALLATION_ID:-$(printf '%s' "$INST_JSON" | jq -r '.id')}"
  SEL="$(printf '%s' "$INST_JSON" | jq -r '.repository_selection')"
  [ "$SEL" = "all" ] || die "The '$APP_SLUG' installation has repository_selection=$SEL.
  The mirror copies every repo, so install it on 'All repositories' of $ORG. With 'selected',
  a new repo would be silently missing from the mirror."
  GOT_PERMS="$(printf '%s' "$INST_JSON" | jq -r '.permissions | to_entries | sort_by(.key) | map("\(.key)=\(.value)") | join(",")')"
  [ "$GOT_PERMS" = "$WANT_PERMS" ] || die "The '$APP_SLUG' App holds permissions: $GOT_PERMS
  It must hold exactly: $WANT_PERMS
  Fix it at github.com/organizations/$ORG/settings/apps/$APP_SLUG/permissions, accept the change
  on the installation, and re-run."
  echo "  repository_selection=all, permissions=$GOT_PERMS"
fi
case "$APP_ID" in ''|*[!0-9]*) die "app_id is not numeric: '$APP_ID'" ;; esac
case "$INSTALLATION_ID" in ''|*[!0-9]*) die "installation_id is not numeric: '$INSTALLATION_ID'" ;; esac
echo "  app_id=$APP_ID  installation_id=$INSTALLATION_ID"

step "Asking the App what it can actually do"
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
NOW="$(date +%s)"
JWT_H="$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)"
JWT_P="$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((NOW - 60))" "$((NOW + 480))" "$APP_ID" | b64url)"
JWT_S="$(printf '%s.%s' "$JWT_H" "$JWT_P" | openssl dgst -sha256 -sign "$PEM_FILE" -binary | b64url)"
# The JWT and the token go to curl on STDIN, never argv: `ps` reads argv.
TOK_JSON="$(printf 'Authorization: Bearer %s.%s.%s\n' "$JWT_H" "$JWT_P" "$JWT_S" | curl -sS --max-time 20 -X POST -H @- \
  -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/app/installations/${INSTALLATION_ID}/access_tokens")"
unset JWT_S
TOKEN="$(printf '%s' "$TOK_JSON" | jq -r '.token // empty')"
[ -n "$TOKEN" ] || die "GitHub would not mint an installation token. It said:
  $(printf '%s' "$TOK_JSON" | jq -r '.message // .' | head -c 300)"
TOK_PERMS="$(printf '%s' "$TOK_JSON" | jq -r '.permissions | to_entries | sort_by(.key) | map("\(.key)=\(.value)") | join(",")')"
[ "$TOK_PERMS" = "$WANT_PERMS" ] || die "A token minted from this key holds: $TOK_PERMS, not $WANT_PERMS."
REPOS_JSON="$(printf 'Authorization: token %s\n' "$TOKEN" | curl -sS --max-time 20 -H @- \
  -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/installation/repositories?per_page=100")"
unset TOKEN
COUNT="$(printf '%s' "$REPOS_JSON" | jq -r '.total_count // empty')"
[ -n "$COUNT" ] && [ "$COUNT" -ge 1 ] || die "The App reaches no repositories. GitHub said:
  $(printf '%s' "$REPOS_JSON" | jq -r '.message // .' | head -c 300)"
OTHER="$(printf '%s' "$REPOS_JSON" | jq -r --arg o "$ORG" '[.repositories[] | select(.owner.login != $o)] | length')"
[ "$OTHER" = 0 ] || die "$OTHER reachable repositories are not owned by $ORG."
echo "  token permissions $TOK_PERMS, $COUNT repositories reached, all owned by $ORG."

step "Authenticating to Vault"
[ -f "$VAULT_CACERT" ] || die "VAULT_CACERT not found at '$VAULT_CACERT'. Run the script from inside the repo, or export VAULT_CACERT."
if [ -z "${VAULT_TOKEN:-}" ]; then
  VAULT_TOKEN="$(security find-generic-password -s "$VAULT_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null || true)"
fi
[ -n "${VAULT_TOKEN:-}" ] || die "No Vault token: set VAULT_TOKEN or add the Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM."
export VAULT_TOKEN
vault token lookup >/dev/null 2>&1 || die "Vault rejected the token, or $VAULT_ADDR is unreachable. Run ./scripts/pet-secrets doctor."

step "Writing $VAULT_PATH"
jq -n --rawfile pem "$PEM_FILE" --arg app_id "$APP_ID" --arg installation_id "$INSTALLATION_ID" \
  '{app_id: $app_id, installation_id: $installation_id, app_pem: $pem}' \
  | vault kv put "$VAULT_PATH" - >/dev/null

step "Verifying by read-back (never printing the key)"
[ "$(vault kv get -field=app_id "$VAULT_PATH")" = "$APP_ID" ] || die "app_id read-back mismatch."
[ "$(vault kv get -field=installation_id "$VAULT_PATH")" = "$INSTALLATION_ID" ] || die "installation_id read-back mismatch."
BACK_LINES="$(vault kv get -field=app_pem "$VAULT_PATH" | wc -l | tr -d ' ')"
[ "$BACK_LINES" -ge 3 ] || die "app_pem came back as $BACK_LINES line(s): the newlines did not survive."
vault kv get -field=app_pem "$VAULT_PATH" | { openssl rsa -noout -check >/dev/null 2>&1 || openssl pkey -noout -check >/dev/null 2>&1; } \
  || die "app_pem read back from Vault does not parse as a key."
echo "  app_id, installation_id and a $BACK_LINES-line key that openssl still accepts."

if [ "$SHRED" -eq 1 ]; then
  step "Removing the downloaded key"
  rm -P "$PEM_FILE" 2>/dev/null || rm -f "$PEM_FILE"
  echo "  $PEM_FILE removed."
else
  step "⚠ The downloaded key is still on disk"
  echo "  $PEM_FILE  — it reads every repo in $ORG. Delete it, or re-run with --shred."
fi

step "Next"
echo "  Deploy: ./scripts/deploy-forgejo-mirror.sh   (docs/runbooks/forgejo-mirror.md)"
