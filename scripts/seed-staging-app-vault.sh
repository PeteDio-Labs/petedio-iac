#!/usr/bin/env bash
# seed-staging-app-vault.sh — put the portfolio staging GitHub App's credentials into Vault at
# kv/services/staging-app, so staging-249 can read the portfolio's `staging` branch.
#
# WHY A SEPARATE APP. staging-249 runs branch code, and its root timer holds this key. The
# petedio-workspace-mirror App reaches five repositories, three of them private, and an App
# caller picks the repositories in its own token request. A key on this host must reach one
# repository, pdlabs-portfolio, with Contents and Metadata read-only, so a root compromise of
# 249 cannot read petedio-vault. This script proves both against GitHub before it writes, as
# seed-workspace-mirror-vault.sh does for its App.
#
# It does not create the App, generate the key or install it. Those are browser steps:
#   1. github.com/organizations/PeteDio-Labs/settings/apps/new, name petedio-portfolio-staging,
#      no webhook, repository permissions Contents: read-only (Metadata is added by GitHub),
#      "Only on this account".
#   2. Generate a private key, and Install App on "Only select repositories": pdlabs-portfolio.
#
#   Vault token: $VAULT_TOKEN, else macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM. Never prompts.
#
# The key is never printed and never passed in argv.
#
# Usage:
#   ./scripts/seed-staging-app-vault.sh ~/Downloads/petedio-portfolio-staging.*.private-key.pem
#   ./scripts/seed-staging-app-vault.sh --shred <pem>   # overwrite + delete the file after

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"
VAULT_PATH="kv/services/staging-app"
ORG="PeteDio-Labs"
# The installation must reach exactly these, in `sort` order, and REPO_COUNT of them.
REPOS="$ORG/pdlabs-portfolio"
REPO_COUNT=1
APP_SLUG="petedio-portfolio-staging"

# The whole permission set the App may hold, as GitHub reports it: sorted "key=value" pairs,
# comma-joined. Anything else — a third permission, or either of these at "write" — fails.
WANT_PERMS="contents=read,metadata=read"

die()  { printf '\033[31mERROR\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

SHRED=0
PEM_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --shred) SHRED=1 ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) PEM_FILE="$1" ;;
  esac
  shift
done

# ---------------------------------------------------------------- the key file
[ -n "$PEM_FILE" ] || die "Pass the .pem downloaded from the App settings page. See --help."
[ -f "$PEM_FILE" ] || die "No such file: $PEM_FILE"
for t in vault openssl curl python3 jq; do command -v "$t" >/dev/null || die "$t not in PATH"; done

step "Checking the private key"
# ⚠ THE CHECK THIS SCRIPT EXISTS FOR. A one-line PEM stores happily and fails at signing
# time with an error that points at the JWT, not at the field.
LINES="$(wc -l < "$PEM_FILE" | tr -d ' ')"
[ "$LINES" -ge 3 ] || die "This PEM is $LINES line(s) — its newlines are gone. Re-download it; do not retype it."
grep -q -- "-----BEGIN" "$PEM_FILE" || die "No PEM header found in $PEM_FILE."
# Prove it is a usable key rather than merely PEM-shaped. Prints a verdict, not the key.
openssl rsa -in "$PEM_FILE" -noout -check >/dev/null 2>&1 \
  || openssl pkey -in "$PEM_FILE" -noout -check >/dev/null 2>&1 \
  || die "openssl cannot parse $PEM_FILE as a private key."
echo "  $LINES lines, header present, openssl parses it."

# ------------------------------------------------------------------- the ids
step "Resolving app_id and installation_id"
APP_ID="${APP_ID:-}"
INSTALLATION_ID="${INSTALLATION_ID:-}"
INST_JSON=""

if command -v gh >/dev/null 2>&1; then
  # Discover from the org's installations. Needs only a user token; the repo-level
  # /installation endpoint wants an App JWT and 401s here, which is expected, not a fault.
  INST_JSON="$(gh api "/orgs/$ORG/installations" \
      --jq ".installations[] | select(.app_slug==\"$APP_SLUG\")" 2>/dev/null || true)"
fi
[ -n "$INST_JSON" ] || [ -n "$APP_ID$INSTALLATION_ID" ] \
  || die "No installation of '$APP_SLUG' found on $ORG, and gh could not be asked.

  Create the App and install it on $REPOS first (App settings -> Install App), or set APP_ID
  and INSTALLATION_ID explicitly."

if [ -n "$INST_JSON" ]; then
  APP_ID="${APP_ID:-$(printf '%s' "$INST_JSON" | jq -r '.app_id')}"
  INSTALLATION_ID="${INSTALLATION_ID:-$(printf '%s' "$INST_JSON" | jq -r '.id')}"

  # ⚠ "SELECTED", NOT "ALL". `repository_selection: all` means the App reads every repository
  # PeteDio-Labs owns, which is the single worst outcome available here and is two clicks away
  # from the correct one on the install page.
  SEL="$(printf '%s' "$INST_JSON" | jq -r '.repository_selection')"
  [ "$SEL" = "selected" ] || die "The '$APP_SLUG' installation has repository_selection=$SEL.

  It must be 'selected', on $REPOS alone. Open
  github.com/organizations/$ORG/settings/installations, choose this App, and set
  'Only select repositories' to $REPOS."

  GOT_PERMS="$(printf '%s' "$INST_JSON" | jq -r '.permissions | to_entries | sort_by(.key) | map("\(.key)=\(.value)") | join(",")')"
  [ "$GOT_PERMS" = "$WANT_PERMS" ] || die "The '$APP_SLUG' App holds permissions: $GOT_PERMS

  It must hold exactly: $WANT_PERMS
  Anything more makes it a worse credential than the one it replaces, and this host runs it
  from a root timer. Fix it at github.com/organizations/$ORG/settings/apps/$APP_SLUG/permissions
  (the install must then accept the change), and re-run."
  echo "  repository_selection=selected, permissions=$GOT_PERMS"
fi

case "$APP_ID" in ''|*[!0-9]*) die "app_id is not numeric: '$APP_ID'" ;; esac
case "$INSTALLATION_ID" in ''|*[!0-9]*) die "installation_id is not numeric: '$INSTALLATION_ID'" ;; esac
echo "  app_id=$APP_ID  installation_id=$INSTALLATION_ID"

# ------------------------------------------------------------------- scope proof
step "Asking the App what it can actually see"
# The permission map above is what GitHub says the App was GRANTED. This is what the App can
# REACH, asked of GitHub with the App's own key. The two disagree when an install was widened
# and the settings page was not, and this is the one that matters at fetch time.
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
NOW="$(date +%s)"
JWT_H="$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)"
JWT_P="$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((NOW - 60))" "$((NOW + 480))" "$APP_ID" | b64url)"
JWT_S="$(printf '%s.%s' "$JWT_H" "$JWT_P" | openssl dgst -sha256 -sign "$PEM_FILE" -binary | b64url)"
JWT="${JWT_H}.${JWT_P}.${JWT_S}"

# The JWT and the token both go to curl on STDIN, never argv: for their lifetime each is
# equivalent to the credential itself, and `ps` reads argv.
TOK_JSON="$(printf 'Authorization: Bearer %s\n' "$JWT" | curl -sS --max-time 20 -X POST -H @- \
  -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/app/installations/${INSTALLATION_ID}/access_tokens")"
unset JWT JWT_S
TOKEN="$(printf '%s' "$TOK_JSON" | jq -r '.token // empty')"
[ -n "$TOKEN" ] || die "GitHub would not mint an installation token. It said:
  $(printf '%s' "$TOK_JSON" | jq -r '.message // .' | head -c 300)

  The usual causes are an app_id that is not this key's App, or an installation_id from a
  different install. Both are on the App's settings page."

REPOS_JSON="$(printf 'Authorization: token %s\n' "$TOKEN" | curl -sS --max-time 20 -H @- \
  -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/installation/repositories?per_page=100")"
unset TOKEN
COUNT="$(printf '%s' "$REPOS_JSON" | jq -r '.total_count // empty')"
[ -n "$COUNT" ] || die "Could not list the installation's repositories. GitHub said:
  $(printf '%s' "$REPOS_JSON" | jq -r '.message // .' | head -c 300)"
NAMES="$(printf '%s' "$REPOS_JSON" | jq -r '[.repositories[].full_name] | sort | join(", ")')"

[ "$COUNT" = "$REPO_COUNT" ] || die "This App reaches $COUNT repositories: $NAMES

  It must reach exactly $REPO_COUNT: $REPOS. Fix the installation and re-run."
[ "$NAMES" = "$REPOS" ] || die "This App reaches '$NAMES', not '$REPOS'.

  Right App, wrong repositories. Fix the installation and re-run."
echo "  $REPO_COUNT repositories, $NAMES, and a token minted from this key reached them."

# ------------------------------------------------------------------- vault
step "Authenticating to Vault"
# ⚠ CHECK THE CA BUNDLE BEFORE BLAMING THE NETWORK. `vault` reports a missing VAULT_CACERT
# as an unreachable server, which sends you to look at .223 when the real fault is a path.
# It happens when this script is copied somewhere else and run from there: REPO_ROOT is
# derived from the script's own location, so from /tmp it resolves to / and the cert is
# sought at //environments/homelab/vault-ca.crt. Run it from the repo, or set VAULT_CACERT.
[ -f "$VAULT_CACERT" ] || die "VAULT_CACERT not found at '$VAULT_CACERT'.
  This is almost always a path problem, not a Vault problem — run the script from inside the
  repo (./scripts/seed-staging-app-vault.sh), or export VAULT_CACERT explicitly."
if [ -z "${VAULT_TOKEN:-}" ]; then
  VAULT_TOKEN="$(security find-generic-password -s "$VAULT_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null || true)"
fi
[ -n "${VAULT_TOKEN:-}" ] || die "No Vault token: set VAULT_TOKEN or add the Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM."
export VAULT_TOKEN
vault token lookup >/dev/null 2>&1 || die "Vault rejected the token, or $VAULT_ADDR is unreachable.
  Check both before assuming either: ./scripts/pet-secrets doctor reports whether Vault is
  sealed and whether the Keychain still holds the bootstrap chain."

step "Writing $VAULT_PATH"
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
  step "The downloaded key is still on disk"
  echo "  $PEM_FILE"
  echo "  It reads $REPOS, a private repository. Delete it, or re-run with --shred."
fi

step "Next"
echo "  Dispatch .github/workflows/deploy-staging-249.yml on main. It reads $VAULT_PATH."
