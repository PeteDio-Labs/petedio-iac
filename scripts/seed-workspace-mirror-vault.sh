#!/usr/bin/env bash
# seed-workspace-mirror-vault.sh — put the petedio-workspace-mirror GitHub App credentials
# into Vault at kv/services/claude-workspace-mirror, so claude-247 can fetch the private
# workspace repo without a login and without a deploy key (PET-493).
#
# WHY AN APP AND NOT A DEPLOY KEY. PeteDio-Labs disallows deploy keys for every repository it
# owns — `gh api orgs/PeteDio-Labs --jq .deploy_keys_enabled_for_repositories` is false — so
# the key PET-481 generated on 247 is one GitHub would never have accepted. An App installed
# on this ONE repository, Contents and Metadata read-only, keeps every property the key was
# chosen for and works.
#
# WHY A SCRIPT AND NOT A PASTE. The private key is multi-line, and a PEM that loses its
# newlines still LOOKS like a key: `vault kv put app_pem=@file` and a copy-paste through a
# terminal both produce something that stores fine and fails later, at which point openssl
# complains about the signature rather than the field. So the newlines are checked here,
# before the value is written, where the error can name the real cause.
#
# ⚠ AND BECAUSE THE SCOPE IS THE SECURITY ARGUMENT, NOT A NOTE ON A TICKET. Every reason to
# prefer this App over a token is "it is read-only and it reaches one repository". This
# script proves both against GitHub before it writes, by minting a token and asking the App
# what it can see. A widened App is caught here, not after a root timer has been using it.
#
# WHAT THIS DOES NOT DO. It does not create the App, generate the key, or install it — those
# are browser steps. It does not deploy anything to 247; that is scripts/deploy-claude-247.sh,
# which reads this path.
#
#   Vault token: $VAULT_TOKEN, else macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM, else prompt
#
# The key is never printed, never passed in argv, and never leaves this process except into
# Vault over TLS and into a signature. Verification reads properties back, never values.
#
# Usage:
#   ./scripts/seed-workspace-mirror-vault.sh ~/Downloads/petedio-workspace-mirror.*.private-key.pem
#   ./scripts/seed-workspace-mirror-vault.sh --shred <pem>   # overwrite + delete the file after
#   APP_ID=... INSTALLATION_ID=... ./scripts/seed-workspace-mirror-vault.sh <pem>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"
VAULT_PATH="kv/services/claude-workspace-mirror"
ORG="PeteDio-Labs"
REPO="petedio-workspace"
APP_SLUG="petedio-workspace-mirror"

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
    -h|--help) sed -n '2,35p' "$0"; exit 0 ;;
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

  Create the App and install it on $REPO first (App settings -> Install App), or set APP_ID
  and INSTALLATION_ID explicitly."

if [ -n "$INST_JSON" ]; then
  APP_ID="${APP_ID:-$(printf '%s' "$INST_JSON" | jq -r '.app_id')}"
  INSTALLATION_ID="${INSTALLATION_ID:-$(printf '%s' "$INST_JSON" | jq -r '.id')}"

  # ⚠ "SELECTED", NOT "ALL". `repository_selection: all` means the App reads every repository
  # PeteDio-Labs owns, which is the single worst outcome available here and is two clicks away
  # from the correct one on the install page.
  SEL="$(printf '%s' "$INST_JSON" | jq -r '.repository_selection')"
  [ "$SEL" = "selected" ] || die "The '$APP_SLUG' installation has repository_selection=$SEL.

  It must be 'selected', on $REPO alone. Open
  github.com/organizations/$ORG/settings/installations, choose this App, and set
  'Only select repositories' to $REPO."

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

# ⚠ NOT THE LOOP'S APP. The loop's App carries contents:write and pull_requests:write. Both
# credentials land on the same host, and the mirror's is read by a root timer.
LOOP_APP_ID="$(vault kv get -field=app_id kv/services/claude-loop 2>/dev/null || true)"
[ -z "$LOOP_APP_ID" ] || [ "$LOOP_APP_ID" != "$APP_ID" ] \
  || die "App $APP_ID is the one already seeded at kv/services/claude-loop.

  That App can push and open pull requests. This path must hold a SECOND App, read-only on
  $REPO. Create it, then re-run."

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

[ "$COUNT" = "1" ] || die "This App reaches $COUNT repositories: $NAMES

  It must reach exactly one: $ORG/$REPO. Narrow the installation and re-run."
[ "$NAMES" = "$ORG/$REPO" ] || die "This App reaches '$NAMES', not '$ORG/$REPO'.

  Right App, wrong repository. Narrow the installation and re-run."
echo "  one repository, $NAMES, and a token minted from this key reached it."

# ------------------------------------------------------------------- vault
step "Authenticating to Vault"
# ⚠ CHECK THE CA BUNDLE BEFORE BLAMING THE NETWORK. `vault` reports a missing VAULT_CACERT
# as an unreachable server, which sends you to look at .223 when the real fault is a path.
# It happens when this script is copied somewhere else and run from there: REPO_ROOT is
# derived from the script's own location, so from /tmp it resolves to / and the cert is
# sought at //environments/homelab/vault-ca.crt. Run it from the repo, or set VAULT_CACERT.
[ -f "$VAULT_CACERT" ] || die "VAULT_CACERT not found at '$VAULT_CACERT'.
  This is almost always a path problem, not a Vault problem — run the script from inside the
  repo (./scripts/seed-workspace-mirror-vault.sh), or export VAULT_CACERT explicitly."
if [ -z "${VAULT_TOKEN:-}" ]; then
  VAULT_TOKEN="$(security find-generic-password -s "$VAULT_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null || true)"
fi
[ -n "${VAULT_TOKEN:-}" ] || { read -rsp "Vault token: " VAULT_TOKEN; echo; }
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
  step "⚠ The downloaded key is still on disk"
  echo "  $PEM_FILE"
  echo "  It reads $ORG/$REPO, which is private. Delete it, or re-run with --shred."
fi

step "Next"
cat <<TXT
  1. Deliver it: ./scripts/deploy-claude-247.sh    # reads $VAULT_PATH, lands the key root-owned
     One run mirrors the repo and clones the session's copy. There is no second pass.
  2. Then the one step no play can take, because the dialog is interactive:

       ssh claude@192.168.50.247
       cd ~/work/petedio/workspace && claude    # accept the trust dialog, then /exit

  3. Rotation, and what to do when a fetch starts failing:
     ansible/roles/claude-code/README.md, "The private workspace repo".
TXT
