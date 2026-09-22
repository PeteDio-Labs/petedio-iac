#!/usr/bin/env bash
# seed-claude-vault-app.sh — put the petedio-vault-247 GitHub App's identity into Vault at
# kv/services/claude-vault-push, so claude-247 can push to the vault repo under its own
# identity (PET-498).
#
# WHY A THIRD APP. claude-247 already holds two GitHub identities: the work loop's App
# (contents:write, pull_requests:write, on petedio-iac, kv/services/claude-loop) and the
# workspace mirror's App (contents:read, metadata:read, on petedio-workspace,
# kv/services/claude-workspace-mirror). Neither reaches petedio-vault, and widening either
# one would hand it a repository it has no reason to touch. petedio-vault-247 is installed on
# petedio-vault alone, with contents:write to push and metadata:read because GitHub requires
# it on every install — nothing else.
#
# WHY A SCRIPT AND NOT A PASTE. The private key is multi-line, and a PEM that loses its
# newlines still looks like a key. `vault kv put app_pem=@file` and a copy-paste through a
# terminal can both produce a value that stores fine and fails later — at which point openssl
# names the signature as broken, not the field. This script checks the newlines before it
# writes, where the error can name the real cause.
#
# WHY THIS CHECKS ITS OWN SCOPE. Every reason to prefer this App over a shared credential is
# "it reaches one repository, and it cannot open pull requests or read the other two". This
# script proves that against GitHub before it writes, by minting a token with the App's own
# key and asking what the token can reach. A widened install is caught here, not after a host
# has been pushing with it for a week.
#
# WHY IT ALSO CHECKS THE OTHER TWO APPS. This App's id must match neither the loop's App id
# nor the mirror's. Both are read from Vault, live, not pinned in this script — pinning them
# would mean the check silently stops working the day either App is rotated.
#
# WHAT THIS DOES NOT DO. It does not create the App, generate its key, or install it on the
# repository — those are browser steps on the App's GitHub settings page. It does not deliver
# the credential to claude-247; wiring a deploy step to read this path is separate work and
# is not done yet.
#
#   Vault token: $VAULT_TOKEN, else macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM, else prompt
#
# The key is never printed, never passed in argv, and never leaves this process except into
# Vault over TLS and into a signature. Verification reads properties back, never values.
#
# Usage:
#   ./scripts/seed-claude-vault-app.sh ~/Downloads/petedio-vault-247.*.private-key.pem
#   ./scripts/seed-claude-vault-app.sh --shred <pem>   # overwrite and delete the file after
#   APP_ID=... INSTALLATION_ID=... ./scripts/seed-claude-vault-app.sh <pem>
set -euo pipefail
umask 077   # Nothing this script touches should be group- or world-readable — it handles a
            # private key start to finish, even though the key itself never lands on disk here.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"
VAULT_PATH="kv/services/claude-vault-push"
LOOP_VAULT_PATH="kv/services/claude-loop"
MIRROR_VAULT_PATH="kv/services/claude-workspace-mirror"
ORG="PeteDio-Labs"
REPO="petedio-vault"
APP_SLUG="petedio-vault-247"

# The whole permission set the App may hold, as GitHub reports it: sorted key=value pairs,
# comma-joined. Anything else — a third permission, or either of these at the wrong level —
# is a refusal.
WANT_PERMS="contents=write,metadata=read"

die()  { printf '\033[31mERROR\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

SHRED=0
PEM_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --shred) SHRED=1 ;;
    -h|--help) sed -n '2,43p' "$0"; exit 0 ;;
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

  Install the App on $REPO first (App settings -> Install App), or set APP_ID and
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
# scripts do it. Those checks read the loop's and the mirror's app_id from Vault, and a read
# that fails because Vault is sealed must never be mistaken for "no conflict found".
[ -f "$VAULT_CACERT" ] || die "VAULT_CACERT not found at '$VAULT_CACERT'.
  This is almost always a path problem, not a Vault problem — run the script from inside the
  repo (./scripts/seed-claude-vault-app.sh), or export VAULT_CACERT explicitly."
if [ -z "${VAULT_TOKEN:-}" ]; then
  VAULT_TOKEN="$(security find-generic-password -s "$VAULT_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null || true)"
fi
[ -n "${VAULT_TOKEN:-}" ] || { read -rsp "Vault token: " VAULT_TOKEN; echo; }
export VAULT_TOKEN
vault token lookup >/dev/null 2>&1 || die "Vault rejected the token, or $VAULT_ADDR is unreachable.
  Check both before assuming either: ./scripts/pet-secrets doctor reports whether Vault is
  sealed and whether the Keychain still holds the bootstrap chain."

step "Checking this App id against the loop's and the mirror's"
# CONDITION 4: this App's id must equal neither the loop's app_id nor the mirror's. Each
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

  This path needs a second App: contents:write and metadata:read on $REPO alone, installed
  under its own id. Create it, install it on $REPO, and re-run with its key."
}
refuse_shared_app_id "$LOOP_VAULT_PATH" "the work loop"
refuse_shared_app_id "$MIRROR_VAULT_PATH" "the workspace mirror"
echo "  app $APP_ID matches neither the loop's app_id nor the mirror's."

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

  It must be 'selected', on $REPO alone. Open
  github.com/organizations/$ORG/settings/installations, choose this App, and set
  'Only select repositories' to $REPO."

# CONDITION 3: permissions must be exactly contents=write, metadata=read — no more, no fewer.
GOT_PERMS="$(printf '%s' "$INSTALL_JSON" | jq -r '.permissions | to_entries | sort_by(.key) | map("\(.key)=\(.value)") | join(",")')"
[ "$GOT_PERMS" = "$WANT_PERMS" ] || die "The '$APP_SLUG' App holds permissions: $GOT_PERMS

  It must hold exactly: $WANT_PERMS
  A stray permission — pull_requests, issues, anything beyond these two — is a refusal, not a
  warning. This key sits on a host next to two Apps that can already push and open pull
  requests. Fix it at github.com/organizations/$ORG/settings/apps/$APP_SLUG/permissions (the
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

# CONDITION 2: the installation must reach exactly one repository, and it must be this one.
[ "$COUNT" = "1" ] || die "This App reaches $COUNT repositories: $NAMES

  It must reach exactly one: $ORG/$REPO. Narrow the installation and re-run."
[ "$NAMES" = "$ORG/$REPO" ] || die "This App reaches '$NAMES', not '$ORG/$REPO'.

  Right App, wrong repository. Narrow the installation and re-run."
echo "  one repository, $NAMES, and a token minted from this key reached it."

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
  echo "  It reaches $ORG/$REPO, which is private. Delete it, or re-run with --shred."
fi

step "Next"
cat <<TXT
  This writes the identity to Vault. It does not deliver it to claude-247 — that needs a
  deploy step that reads $VAULT_PATH, which is separate work and is not wired up yet.

  Read it back any time without printing the key:
    vault kv get -field=app_id $VAULT_PATH
    vault kv get -field=installation_id $VAULT_PATH

  Rotation: repeat this script with the new .pem. The old key stops working the moment
  GitHub issues the new one, so there is no overlap window to plan around.
TXT
