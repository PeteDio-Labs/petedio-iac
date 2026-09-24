#!/usr/bin/env bash
# seed-claude-code-app.sh — put the petedio-code-247 GitHub App's identity into Vault at
# kv/services/claude-code-push, so a session on claude-247 can push branches to three code
# repositories and open pull requests on them (PET-507).
#
# WHY A FOURTH APP. claude-247 already holds three GitHub identities: the work loop's App
# (kv/services/claude-loop), the workspace mirror's read-only App
# (kv/services/claude-workspace-mirror) and the vault push App (kv/services/claude-vault-push).
# The loop's key is root's, and a session must never read it. The mirror's App cannot write.
# The vault App reaches petedio-vault alone. petedio-code-247 is installed on petedio-iac,
# petedio-media-iac and petedio-workspace, with contents:write to push, pull_requests:write to
# open pull requests, and metadata:read because GitHub requires it on every install.
#
# ⚠ NO `workflows` PERMISSION, ON PURPOSE. Without it GitHub refuses any push that touches
# .github/workflows/**. That keeps a session from rewriting the jobs that run on merge.
#
# WHY A SCRIPT AND NOT A PASTE. The private key is multi-line, and a PEM that loses its
# newlines still looks like a key. This script checks the newlines before it writes, where the
# error can name the real cause.
#
# WHY THIS CHECKS ITS OWN SCOPE. This script mints a token with the App's own key and asks
# GitHub what the token can reach, before it writes. A widened install is caught here, not
# after a host has been pushing with it for a week.
#
# WHY IT CHECKS THE OTHER THREE APPS. This App's id must match none of the loop's, the
# mirror's or the vault App's. Each is read from Vault, live, so the check survives rotation.
#
# WHAT THIS DOES NOT DO. It does not create the App, generate its key or install it. Those are
# browser steps on the App's GitHub settings page. scripts/deploy-claude-247.sh delivers the
# credential to claude-247 from this Vault path.
#
#   Vault token: $VAULT_TOKEN, else macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM, else prompt
#
# The key is never printed, never passed in argv, and never leaves this process except into
# Vault over TLS and into a signature. Verification reads properties back, never values.
#
# Usage:
#   ./scripts/seed-claude-code-app.sh ~/Downloads/petedio-code-247.*.private-key.pem
#   ./scripts/seed-claude-code-app.sh --shred <pem>   # overwrite and delete the file after
#   APP_ID=... INSTALLATION_ID=... ./scripts/seed-claude-code-app.sh <pem>
set -euo pipefail
umask 077   # Nothing this script touches should be group- or world-readable — it handles a
            # private key start to finish, even though the key itself never lands on disk here.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"
VAULT_PATH="kv/services/claude-code-push"
LOOP_VAULT_PATH="kv/services/claude-loop"
MIRROR_VAULT_PATH="kv/services/claude-workspace-mirror"
VAULT_APP_VAULT_PATH="kv/services/claude-vault-push"
ORG="PeteDio-Labs"
# The exact set the install must reach, as GitHub lists full names: sorted, comma-joined.
WANT_REPOS="PeteDio-Labs/petedio-iac, PeteDio-Labs/petedio-media-iac, PeteDio-Labs/petedio-workspace"
WANT_COUNT=3
APP_SLUG="${APP_SLUG:-petedio-code-247}"

# The whole permission set the App may hold, as GitHub reports it: sorted key=value pairs,
# comma-joined. Anything else — `workflows`, `administration`, or one of these at the wrong
# level — is a refusal.
WANT_PERMS="contents=write,metadata=read,pull_requests=write"

die()  { printf '\033[31mERROR\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

SHRED=0
PEM_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --shred) SHRED=1 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) PEM_FILE="$1" ;;
  esac
  shift
done

# ---------------------------------------------------------------- the key file
[ -n "$PEM_FILE" ] || die "Pass the .pem downloaded from the App settings page. See --help."
[ -f "$PEM_FILE" ] || die "No such file: $PEM_FILE"
for t in vault openssl curl jq; do command -v "$t" >/dev/null || die "$t not in PATH"; done

step "Checking the private key"
# The check this script exists for. A one-line PEM stores without complaint and fails at
# signing time, with an error that names the JWT, not the field that caused it.
LINES="$(wc -l < "$PEM_FILE" | tr -d ' ')"
[ "$LINES" -ge 3 ] || die "This PEM is $LINES line(s) — its newlines are gone. Re-download it; do not retype it."
grep -q -- "-----BEGIN" "$PEM_FILE" || die "No PEM header found in $PEM_FILE."
# Prove it is a usable key, not merely PEM-shaped. Prints a verdict, never the key.
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
  # Discovery only. gh's user token can list an org's installations by slug, but it cannot
  # speak for the App the way the App's own key can — repository_selection and permissions
  # are re-read from GitHub with that key below. A failure here costs only auto-discovery, so
  # its stderr is left to print rather than hidden: nothing downstream depends on it quietly.
  INST_JSON="$(gh api "/orgs/$ORG/installations" \
      --jq ".installations[] | select(.app_slug==\"$APP_SLUG\")" || true)"
fi
[ -n "$INST_JSON" ] || [ -n "$APP_ID$INSTALLATION_ID" ] \
  || die "No installation of '$APP_SLUG' found on $ORG, and gh could not be asked.

  Install the App on the three repositories first (App settings -> Install App), or set APP_ID and
  INSTALLATION_ID explicitly and re-run."

if [ -n "$INST_JSON" ]; then
  APP_ID="${APP_ID:-$(printf '%s' "$INST_JSON" | jq -r '.app_id')}"
  INSTALLATION_ID="${INSTALLATION_ID:-$(printf '%s' "$INST_JSON" | jq -r '.id')}"
fi

case "$APP_ID" in ''|*[!0-9]*) die "app_id is not numeric: '$APP_ID'" ;; esac
case "$INSTALLATION_ID" in ''|*[!0-9]*) die "installation_id is not numeric: '$INSTALLATION_ID'" ;; esac
echo "  app_id=$APP_ID  installation_id=$INSTALLATION_ID"

# ---------------------------------------------------------------------- vault
step "Authenticating to Vault"
# Authenticated here, ahead of the id-collision checks below — earlier than the sibling
# scripts do it. Those checks read the other three Apps' app_id from Vault, and a read
# that fails because Vault is sealed must never be mistaken for "no conflict found".
[ -f "$VAULT_CACERT" ] || die "VAULT_CACERT not found at '$VAULT_CACERT'.
  This is almost always a path problem, not a Vault problem — run the script from inside the
  repo (./scripts/seed-claude-code-app.sh), or export VAULT_CACERT explicitly."
if [ -z "${VAULT_TOKEN:-}" ]; then
  VAULT_TOKEN="$(security find-generic-password -s "$VAULT_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null || true)"
fi
[ -n "${VAULT_TOKEN:-}" ] || { read -rsp "Vault token: " VAULT_TOKEN; echo; }
export VAULT_TOKEN
vault token lookup >/dev/null 2>&1 || die "Vault rejected the token, or $VAULT_ADDR is unreachable.
  Check both before assuming either: ./scripts/pet-secrets doctor reports whether Vault is
  sealed and whether the Keychain still holds the bootstrap chain."

step "Checking this App id against the other three Apps on claude-247"
# CONDITION 4: this App's id must equal none of the other three app_ids. Each
# check reads the other path's app_id from Vault; a read that FAILS — sealed Vault, revoked
# token, network fault — dies with that fact, rather than being read as "no conflict found".
refuse_shared_app_id() {
  local path="$1" owner="$2" other_id
  if ! other_id="$(vault kv get -field=app_id "$path" 2>&1)"; then
    die "Could not read $path to check its app_id against this one. Vault said:
  $other_id

  $owner's App is already seeded at this path, so a failed read here is more likely a sealed
  Vault than an empty one. Run ./scripts/pet-secrets doctor, unseal if needed, and re-run —
  do not re-run with this check skipped."
  fi
  [ -z "$other_id" ] || [ "$other_id" != "$APP_ID" ] \
    || die "App $APP_ID is the one already seeded at $path ($owner's).

  This path needs its own App: $WANT_PERMS on the three code repositories, installed
  under its own id. Create it, install it, and re-run with its key."
}
refuse_shared_app_id "$LOOP_VAULT_PATH" "the work loop"
refuse_shared_app_id "$MIRROR_VAULT_PATH" "the workspace mirror"
refuse_shared_app_id "$VAULT_APP_VAULT_PATH" "the vault push"
echo "  app $APP_ID matches none of the loop's, the mirror's or the vault push App's app_id."

# ---------------------------------------------------------------- scope proof
step "Asking GitHub what this App's own key proves"
# repository_selection and permissions come from the install endpoint, read with a JWT signed
# by this key: what the App can prove about itself, not what gh's user-token listing reported
# above. That keeps this check running even when APP_ID and INSTALLATION_ID came from the
# environment instead of gh. Which repositories a minted token can reach is asked separately
# below, because an install's own record of itself and what its token actually lists have
# disagreed before, on an install that was widened without a re-sync.
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
NOW="$(date +%s)"
JWT_H="$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)"
JWT_P="$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((NOW - 60))" "$((NOW + 480))" "$APP_ID" | b64url)"
JWT_S="$(printf '%s.%s' "$JWT_H" "$JWT_P" | openssl dgst -sha256 -sign "$PEM_FILE" -binary | b64url)"
JWT="${JWT_H}.${JWT_P}.${JWT_S}"

# The JWT reaches curl on stdin for both calls below, never argv: for its lifetime it is
# equivalent to the private key itself, and `ps` reads argv.
INSTALL_JSON="$(printf 'Authorization: Bearer %s\n' "$JWT" | curl -sS --max-time 20 -H @- \
  -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/app/installations/${INSTALLATION_ID}")"
TOK_JSON="$(printf 'Authorization: Bearer %s\n' "$JWT" | curl -sS --max-time 20 -X POST -H @- \
  -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/app/installations/${INSTALLATION_ID}/access_tokens")"
unset JWT JWT_S

SEL="$(printf '%s' "$INSTALL_JSON" | jq -r '.repository_selection // empty')"
[ -n "$SEL" ] || die "GitHub would not describe installation $INSTALLATION_ID. It said:
  $(printf '%s' "$INSTALL_JSON" | jq -r '.message // .' | head -c 300)

  The usual causes are an app_id that is not this key's App, or an installation_id from a
  different install. Both are on the App's settings page."

# CONDITION 1: repository_selection must be 'selected', not 'all'. 'all' means the App reads
# every repository PeteDio-Labs owns, and is two clicks away from the correct setting.
[ "$SEL" = "selected" ] || die "The '$APP_SLUG' installation has repository_selection=$SEL.

  It must be 'selected', on exactly: $WANT_REPOS. Open
  github.com/organizations/$ORG/settings/installations, choose this App, and set
  'Only select repositories' to those three."

# CONDITION 3: permissions must be exactly $WANT_PERMS — no more, no fewer.
GOT_PERMS="$(printf '%s' "$INSTALL_JSON" | jq -r '.permissions | to_entries | sort_by(.key) | map("\(.key)=\(.value)") | join(",")')"
[ "$GOT_PERMS" = "$WANT_PERMS" ] || die "The '$APP_SLUG' App holds permissions: $GOT_PERMS

  It must hold exactly: $WANT_PERMS
  A stray permission — workflows, administration, issues, anything beyond these three — is a
  refusal, not a warning. A session on claude-247 can read this key. Fix it at github.com/organizations/$ORG/settings/apps/$APP_SLUG/permissions (the
  install must then accept the change), and re-run."
echo "  repository_selection=selected, permissions=$GOT_PERMS"

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

# CONDITION 2: the installation must reach exactly the three code repositories.
[ "$COUNT" = "$WANT_COUNT" ] || die "This App reaches $COUNT repositories: $NAMES

  It must reach exactly $WANT_COUNT: $WANT_REPOS. Fix the installation and re-run."
[ "$NAMES" = "$WANT_REPOS" ] || die "This App reaches '$NAMES', not '$WANT_REPOS'.

  Right App, wrong repositories. Fix the installation and re-run."
echo "  $WANT_COUNT repositories, $NAMES, and a token minted from this key reached them."

# ----------------------------------------------------------------- vault write
step "Writing $VAULT_PATH"
# --rawfile slurps the key as one JSON string with its newlines intact. Stdin keeps it out of
# argv, where `ps` would show it.
jq -n --rawfile pem "$PEM_FILE" --arg app_id "$APP_ID" --arg installation_id "$INSTALLATION_ID" \
  '{app_id: $app_id, installation_id: $installation_id, app_pem: $pem}' \
  | vault kv put "$VAULT_PATH" - >/dev/null

step "Verifying by read-back (never printing the key)"
[ "$(vault kv get -field=app_id "$VAULT_PATH")" = "$APP_ID" ] || die "app_id read-back mismatch."
[ "$(vault kv get -field=installation_id "$VAULT_PATH")" = "$INSTALLATION_ID" ] || die "installation_id read-back mismatch."
BACK_LINES="$(vault kv get -field=app_pem "$VAULT_PATH" | wc -l | tr -d ' ')"
[ "$BACK_LINES" -ge 3 ] || die "app_pem came back as $BACK_LINES line(s) — the newlines did not survive."
vault kv get -field=app_pem "$VAULT_PATH" \
  | { openssl rsa -noout -check >/dev/null 2>&1 || openssl pkey -noout -check >/dev/null 2>&1; } \
  || die "app_pem read back from Vault does not parse as a key."
echo "  app_id, installation_id, and a $BACK_LINES-line key that openssl still accepts."

# -------------------------------------------------------------------- cleanup
if [ "$SHRED" -eq 1 ]; then
  step "Removing the downloaded key"
  rm -P "$PEM_FILE" 2>/dev/null || rm -f "$PEM_FILE"
  echo "  $PEM_FILE removed."
else
  step "The downloaded key is still on disk"
  echo "  $PEM_FILE"
  echo "  It pushes to three repositories. Delete it, or re-run with --shred."
fi

step "Next"
cat <<TXT
  This writes the identity to Vault. To deliver it to claude-247, run
  ./scripts/deploy-claude-247.sh, which reads $VAULT_PATH.

  Read it back any time without printing the key:
    vault kv get -field=app_id $VAULT_PATH
    vault kv get -field=installation_id $VAULT_PATH

  Rotation: repeat this script with the new .pem. The old key stops working the moment
  GitHub issues the new one, so there is no overlap window to plan around.
TXT
