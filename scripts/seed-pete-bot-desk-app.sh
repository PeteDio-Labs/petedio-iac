#!/usr/bin/env bash
# seed-pete-bot-desk-app.sh — put the pete-bot merge desk's GitHub App identity into Vault
# at kv/services/pete-bot, as desk_app_id, desk_installation_id and desk_app_pem (PET-645).
# Modeled on seed-codex-review-app.sh.
#
# WHY A PATCH ON THE BOT'S OWN PATH. pete-bot's deploy role, pete-bot-cd, reads
# kv/services/pete-bot and nothing else of the bot's. Three fields there need no policy
# change. `vault kv patch` writes them and keeps the Discord token and the bearers as they
# are, and the read-back proves it.
#
# WHAT THE APP MAY DO. contents:write and pull_requests:write, to approve and squash-merge;
# checks:read and statuses:read, to see CI on private repositories; metadata:read. Nothing
# else: no `workflows`, no administration, and no checks:write, which would let the App post
# its own passing result.
#
# WHERE IT IS INSTALLED. Selected repositories only, each on ALLOWED_REPOS below. The desk
# merges in the repos its DESK_REPOS names, and reads the tier rules from petedio-iac. An
# install that reaches any other repository is a refusal.
#
# WHY THIS CHECKS ITS OWN SCOPE. The script mints a token with the App's own key and asks
# GitHub what the install holds, before it writes. A widened permission is caught here.
#
# WHY IT CHECKS THE OTHER APPS. The desk approves PRs, so it must be none of the Apps that
# author them or review them. Each is read from Vault, live, so the check survives rotation.
#
# WHAT THIS DOES NOT DO. It does not create the App, generate its key or install it. Those
# are browser steps. scripts/deploy-pete-bot.sh delivers the identity to media-dash-237.
#
#   Vault token: $VAULT_TOKEN, else the macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM.
#   This script never prompts for it.
#
# The key is never printed and never passed in argv. Verification reads properties back,
# never values.
#
# Usage:
#   ./scripts/seed-pete-bot-desk-app.sh ~/Downloads/pete-bot-merge-desk.*.private-key.pem
#   ./scripts/seed-pete-bot-desk-app.sh --shred <pem>   # delete the file afterward
#   APP_ID=... INSTALLATION_ID=... ./scripts/seed-pete-bot-desk-app.sh <pem>
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"
VAULT_PATH="kv/services/pete-bot"
ORG="PeteDio-Labs"
APP_SLUG="${APP_SLUG:-pete-bot-merge-desk}"
# The whole permission set, as GitHub reports it: sorted key=value pairs, comma-joined.
WANT_PERMS="checks=read,contents=write,metadata=read,pull_requests=write,statuses=read"
# The repositories the install may reach. The install may reach fewer, never more.
ALLOWED_REPOS=(petedio-workspace petedio-vault petedio-pm petedio-iac petedio-media-iac)
# Apps that author or review PRs. The desk approves PRs, so it must be none of them.
OTHER_APPS=(
  "kv/services/codex-review-app|the Codex reviewer"
  "kv/services/claude-workspace-mirror|the workspace mirror"
  "kv/services/claude-vault-push|the vault push"
  "kv/services/claude-code-push|the code push"
  "kv/services/claude-ops-github|claude-ops"
)

die()  { printf '\033[31mERROR\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

SHRED=0
PEM_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --shred) SHRED=1 ;;
    -h|--help) sed -n '2,38p' "$0"; exit 0 ;;
    *) PEM_FILE="$1" ;;
  esac
  shift
done

# ---------------------------------------------------------------- the key file
[ -n "$PEM_FILE" ] || die "Pass the .pem downloaded from the App settings page. See --help."
[ -f "$PEM_FILE" ] || die "No such file: $PEM_FILE"
for t in vault openssl curl jq gh security; do command -v "$t" >/dev/null || die "$t not in PATH"; done

step "Checking the private key"
LINES="$(wc -l < "$PEM_FILE" | tr -d ' ')"
[ "$LINES" -ge 3 ] || die "This PEM is $LINES line(s); its newlines are gone. Download it again; do not retype it."
grep -q -- "-----BEGIN" "$PEM_FILE" || die "No PEM header found in $PEM_FILE."
openssl rsa -in "$PEM_FILE" -noout -check >/dev/null 2>&1 \
  || openssl pkey -in "$PEM_FILE" -noout -check >/dev/null 2>&1 \
  || die "openssl cannot parse $PEM_FILE as a private key."
echo "  $LINES lines, header present, openssl parses it."

# ------------------------------------------------------------------- the ids
step "Resolving app_id and installation_id"
APP_ID="${APP_ID:-}"
INSTALLATION_ID="${INSTALLATION_ID:-}"
if [ -z "$APP_ID" ] || [ -z "$INSTALLATION_ID" ]; then
  # Discovery only. The App's own key re-reads the install below.
  INST_JSON="$(gh api "/orgs/$ORG/installations" --paginate \
      --jq ".installations[] | select(.app_slug==\"$APP_SLUG\")")" \
    || die "gh could not list $ORG's installations. Set APP_ID and INSTALLATION_ID, and run this again."
  [ -n "$INST_JSON" ] || die "No installation of '$APP_SLUG' on $ORG.
  Install the App first: github.com/organizations/$ORG/settings/apps/$APP_SLUG/installations"
  APP_ID="${APP_ID:-$(printf '%s' "$INST_JSON" | jq -r '.app_id')}"
  INSTALLATION_ID="${INSTALLATION_ID:-$(printf '%s' "$INST_JSON" | jq -r '.id')}"
fi
case "$APP_ID" in ''|*[!0-9]*) die "app_id is not numeric: '$APP_ID'" ;; esac
case "$INSTALLATION_ID" in ''|*[!0-9]*) die "installation_id is not numeric: '$INSTALLATION_ID'" ;; esac
echo "  app_id=$APP_ID  installation_id=$INSTALLATION_ID"

# ---------------------------------------------------------------------- vault
step "Authenticating to Vault"
[ -f "$VAULT_CACERT" ] || die "VAULT_CACERT not found at '$VAULT_CACERT'. Run the script from the repo, or export VAULT_CACERT."
if [ -z "${VAULT_TOKEN:-}" ]; then
  VAULT_TOKEN="$(security find-generic-password -s "$VAULT_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null || true)"
fi
[ -n "${VAULT_TOKEN:-}" ] || die "No Vault token. Export VAULT_TOKEN, or store it in the Keychain item '$VAULT_TOKEN_KEYCHAIN_ITEM'."
export VAULT_TOKEN
vault token lookup >/dev/null 2>&1 || die "Vault rejected the token, or $VAULT_ADDR is unreachable.
  Run ./scripts/pet-secrets doctor to see whether Vault is sealed."

step "Checking this App id against the other Apps"
# A failed read dies with that fact. A sealed Vault must never read as "no conflict found".
# Vault's "No value found" is the one failure that means absent: kv/services/claude-ops-github
# was unseeded on 2026-10-01, and an App with no key in Vault cannot be this one.
for entry in "${OTHER_APPS[@]}"; do
  path="${entry%%|*}" owner="${entry#*|}"
  if ! other_id="$(vault kv get -field=app_id "$path" 2>&1)"; then
    case "$other_id" in
      "No value found at "*) echo "  $path is not seeded ($owner), so it cannot conflict."; continue ;;
    esac
    die "Could not read $path to compare its app_id. Vault said:
  $other_id
  Run ./scripts/pet-secrets doctor, unseal if needed, and run this again."
  fi
  [ "$other_id" != "$APP_ID" ] || die "App $APP_ID is $owner's App, seeded at $path.
  The merge desk needs its own App, $APP_SLUG."
done
echo "  app $APP_ID matches none of them."

# ---------------------------------------------------------------- scope proof
step "Asking GitHub what this App's own key proves"
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
NOW="$(date +%s)"
JWT_H="$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)"
JWT_P="$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((NOW - 60))" "$((NOW + 480))" "$APP_ID" | b64url)"
JWT_S="$(printf '%s.%s' "$JWT_H" "$JWT_P" | openssl dgst -sha256 -sign "$PEM_FILE" -binary | b64url)"
JWT="${JWT_H}.${JWT_P}.${JWT_S}"
gh_jwt() {
  printf 'Authorization: Bearer %s\n' "$JWT" | curl -sS --max-time 20 -H @- \
    -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" "$@"
}
APP_JSON="$(gh_jwt "https://api.github.com/app")"
INSTALL_JSON="$(gh_jwt "https://api.github.com/app/installations/${INSTALLATION_ID}")"
TOK_JSON="$(gh_jwt -X POST "https://api.github.com/app/installations/${INSTALLATION_ID}/access_tokens")"
unset JWT JWT_S

GOT_SLUG="$(printf '%s' "$APP_JSON" | jq -r '.slug // empty')"
[ "$GOT_SLUG" = "$APP_SLUG" ] || die "This key belongs to App '${GOT_SLUG:-unknown}', not $APP_SLUG. GitHub said:
  $(printf '%s' "$APP_JSON" | jq -r '.message // empty' | head -c 300)"

SEL="$(printf '%s' "$INSTALL_JSON" | jq -r '.repository_selection // empty')"
ACCOUNT="$(printf '%s' "$INSTALL_JSON" | jq -r '.account.login // empty')"
[ -n "$SEL" ] || die "GitHub would not describe installation $INSTALLATION_ID. It said:
  $(printf '%s' "$INSTALL_JSON" | jq -r '.message // .' | head -c 300)"
[ "$ACCOUNT" = "$ORG" ] || die "Installation $INSTALLATION_ID is on '$ACCOUNT', not $ORG."
[ "$SEL" = "selected" ] || die "The installation has repository_selection=$SEL. It must reach selected repositories only.
  Change it at github.com/organizations/$ORG/settings/installations/$INSTALLATION_ID"

GOT_PERMS="$(printf '%s' "$INSTALL_JSON" | jq -r '.permissions | to_entries | sort_by(.key) | map("\(.key)=\(.value)") | join(",")')"
[ "$GOT_PERMS" = "$WANT_PERMS" ] || die "The App holds permissions: $GOT_PERMS
  It must hold exactly: $WANT_PERMS
  Any other permission is a refusal. Fix it at
  github.com/organizations/$ORG/settings/apps/$APP_SLUG/permissions, accept the change on the
  install, and run this again."
echo "  slug=$GOT_SLUG, account=$ACCOUNT, repository_selection=selected, permissions=$GOT_PERMS"

TOKEN="$(printf '%s' "$TOK_JSON" | jq -r '.token // empty')"
[ -n "$TOKEN" ] || die "GitHub would not mint an installation token. It said:
  $(printf '%s' "$TOK_JSON" | jq -r '.message // .' | head -c 300)"
REACHED="$(printf 'Authorization: token %s\n' "$TOKEN" | curl -sS --max-time 20 -H @- \
  -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/installation/repositories?per_page=100" | jq -r '.repositories[]?.name')"
unset TOKEN
[ -n "$REACHED" ] || die "A token minted from this key reaches no repository. Install the App on the desk's repositories."
COUNT=0
for r in $REACHED; do
  COUNT=$((COUNT + 1))
  case " ${ALLOWED_REPOS[*]} " in
    *" $r "*) ;;
    *) die "A token minted from this key reaches $r, which is not on ALLOWED_REPOS. Remove it from the install." ;;
  esac
done
echo "  A token minted from this key reaches $COUNT repositories, all on ALLOWED_REPOS: $(printf '%s' "$REACHED" | tr '\n' ' ')"

# ----------------------------------------------------------------- vault write
step "Writing three fields of $VAULT_PATH"
names() { vault kv get -format=json "$VAULT_PATH" | jq -r '.data.data | keys | sort | join(" ")'; }
BEFORE="$(names)" || die "$VAULT_PATH is absent or unreadable. Run scripts/seed-pete-bot-vault.sh first."
DISCORD_SUM="$(vault kv get -field=discord_token "$VAULT_PATH" | openssl dgst -sha256)"
jq -n --rawfile pem "$PEM_FILE" --arg app_id "$APP_ID" --arg installation_id "$INSTALLATION_ID" \
  '{desk_app_id: $app_id, desk_installation_id: $installation_id, desk_app_pem: $pem}' \
  | vault kv patch "$VAULT_PATH" - >/dev/null || die "vault kv patch failed for $VAULT_PATH."

step "Verifying by read-back (never printing the key)"
[ "$(vault kv get -field=desk_app_id "$VAULT_PATH")" = "$APP_ID" ] || die "desk_app_id read-back mismatch."
[ "$(vault kv get -field=desk_installation_id "$VAULT_PATH")" = "$INSTALLATION_ID" ] || die "desk_installation_id read-back mismatch."
BACK_LINES="$(vault kv get -field=desk_app_pem "$VAULT_PATH" | wc -l | tr -d ' ')"
[ "$BACK_LINES" -ge 3 ] || die "desk_app_pem came back as $BACK_LINES line(s); the newlines did not survive."
vault kv get -field=desk_app_pem "$VAULT_PATH" \
  | { openssl rsa -noout -check >/dev/null 2>&1 || openssl pkey -noout -check >/dev/null 2>&1; } \
  || die "desk_app_pem read back from Vault does not parse as a key."
[ "$(vault kv get -field=discord_token "$VAULT_PATH" | openssl dgst -sha256)" = "$DISCORD_SUM" ] \
  || die "the patch changed discord_token."
AFTER="$(names)"
for f in $BEFORE; do
  case " $AFTER " in *" $f "*) ;; *) die "the patch dropped the field $f." ;; esac
done
echo "  desk_app_id, desk_installation_id, and a $BACK_LINES-line key that openssl accepts."
echo "  fields: $AFTER"

# -------------------------------------------------------------------- cleanup
if [ "$SHRED" -eq 1 ]; then
  step "Removing the downloaded key"
  rm -P "$PEM_FILE" 2>/dev/null || rm -f "$PEM_FILE"
  echo "  $PEM_FILE removed."
else
  step "The downloaded key is still on disk"
  echo "  $PEM_FILE"
  echo "  It can merge in every repository the install reaches. Delete it, or run this again with --shred."
fi

step "Next"
cat <<TXT
  To deliver the identity to media-dash-237, run ./scripts/deploy-pete-bot.sh, or merge to
  pete-bot's main. The desk stays off until pete_bot_desk_mode is dry-run or on.
  To rotate the key, generate a new one on the App's page, run this script with it, run the
  deploy, then delete the old key on the App's page.
TXT
