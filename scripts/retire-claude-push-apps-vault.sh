#!/usr/bin/env bash
# retire-claude-push-apps-vault.sh — permanently delete kv/services/claude-code-push and
# kv/services/claude-vault-push, the keys of the two retired 247 push Apps (PET-594).
#
# RUN IT AFTER BOTH APPS ARE GONE AT GITHUB. petedio-code-247 and petedio-vault-247 were
# deleted at GitHub before 2026-10-19, which revoked their keys: the Mac's read on PET-594
# that day got 404 for both. This script removes the copies in Vault: every version and the
# metadata, so no `vault kv undelete` or rollback can restore them. It refuses while GitHub
# still answers for either App, because a live App with no key in Vault is an identity
# nobody can rotate.
#
# WHY A SCRIPT. A credential change is never made by hand in this lab (PET-511). Pedro runs
# this from the Mac, and the script says what it examined and verifies the result.
#
# WHAT THIS DOES NOT DO. It does not touch kv/services/claude-ops-github, the key 247 uses
# today. It does not change the 247 deploy: scripts/deploy-claude-247.sh reads both paths as
# optional, and an empty path leaves the push feature off, so roles/claude-code's
# push-apps-retired.yml keeps the host clean (PET-643).
#
#   Vault token: $VAULT_TOKEN, else macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM. No
#   interactive prompt — set one of those first, or this refuses to run.
#
# Usage:
#   ./scripts/retire-claude-push-apps-vault.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"
KV_PATHS=(kv/services/claude-code-push kv/services/claude-vault-push)
APP_SLUGS=(petedio-code-247 petedio-vault-247)

die()  { printf '\033[31mERROR\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

for t in vault gh; do command -v "$t" >/dev/null || die "$t not in PATH"; done

# ------------------------------------------------------------------- github
step "Asking GitHub whether the two retired Apps still exist"
# ⚠ ASK AS AN ORG OWNER, NEVER ANONYMOUSLY. GET /apps/<slug> answers 404 to an anonymous
# request for a PRIVATE App that exists. So this asks through gh, and first proves the token
# can see a private App at all: CONTROL_SLUG is a private App that must exist. Without that
# control, a token with no view of the org's Apps reads every App as deleted.
CONTROL_SLUG="${CONTROL_SLUG:-petedio-ops-247}"
gh api "/apps/$CONTROL_SLUG" --jq .id >/dev/null 2>&1 || die "gh cannot see the private App
  $CONTROL_SLUG, so a 404 for the retired Apps would prove nothing. Examined nothing. Check
  \`gh auth status\` names an owner of PeteDio-Labs, then re-run."
echo "  control: gh sees the private App $CONTROL_SLUG."
for APP_SLUG in "${APP_SLUGS[@]}"; do
  if OUT="$(gh api "/apps/$APP_SLUG" --jq .id 2>&1)"; then
    die "GitHub still answers for $APP_SLUG (id $OUT). Delete the App first, at
  https://github.com/organizations/PeteDio-Labs/settings/apps/$APP_SLUG/advanced
  then re-run this script."
  fi
  case "$OUT" in
    *"HTTP 404"*) echo "  gh api /apps/$APP_SLUG answered 404: the App is deleted." ;;
    *) die "Could not ask GitHub about $APP_SLUG. Examined nothing. gh said:
  $OUT" ;;
  esac
done

# -------------------------------------------------------------------- vault
step "Authenticating to Vault"
[ -f "$VAULT_CACERT" ] || die "VAULT_CACERT not found at '$VAULT_CACERT'.
  Run the script from inside the repo (./scripts/retire-claude-push-apps-vault.sh), or export
  VAULT_CACERT explicitly."
if [ -z "${VAULT_TOKEN:-}" ]; then
  VAULT_TOKEN="$(security find-generic-password -s "$VAULT_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null || true)"
fi
[ -n "${VAULT_TOKEN:-}" ] || die "no Vault token: set VAULT_TOKEN or add the Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM. This script does not prompt."
export VAULT_TOKEN
vault token lookup >/dev/null 2>&1 || die "Vault rejected the token, or $VAULT_ADDR is unreachable.
  Check both before assuming either: ./scripts/pet-secrets doctor reports whether Vault is
  sealed and whether the Keychain still holds the bootstrap chain."

# ⚠ A read that fails is not a read that found nothing. Only Vault's own "No value found"
# answer counts as absent; a sealed Vault or a denied read dies with what Vault said.
kv_state() {
  local out
  if out="$(vault kv metadata get "$1" 2>&1)"; then
    echo present
  elif printf '%s' "$out" | grep -q 'No value found at'; then
    echo absent
  else
    die "Could not read the metadata at $1. Vault said:
  $out"
  fi
}

# Read both paths before deleting either, so a failed read stops the script with nothing
# deleted.
step "Reading both paths"
# An indexed array, not an associative one: the Mac's /bin/bash is 3.2.
STATES=()
for KV_PATH in "${KV_PATHS[@]}"; do
  STATE="$(kv_state "$KV_PATH")"
  STATES+=("$STATE")
  echo "  $KV_PATH: $STATE"
done

for i in "${!KV_PATHS[@]}"; do
  KV_PATH="${KV_PATHS[$i]}"
  case "${STATES[$i]}" in
    absent)  echo "  $KV_PATH is already absent. Nothing to delete." ;;
    present)
      step "Deleting every version and the metadata of $KV_PATH"
      vault kv metadata delete "$KV_PATH" >/dev/null || die "vault kv metadata delete $KV_PATH failed." ;;
    *) die "unexpected state '${STATES[$i]}' for $KV_PATH" ;;
  esac
done

step "Verifying"
for KV_PATH in "${KV_PATHS[@]}"; do
  AFTER="$(kv_state "$KV_PATH")"
  case "$AFTER" in
    absent)  echo "  $KV_PATH reads as not found. Verified." ;;
    present) die "$KV_PATH still has metadata after the delete. Read it with:
  vault kv metadata get $KV_PATH" ;;
    *)       die "unexpected state '$AFTER' for $KV_PATH" ;;
  esac
done
echo "  Examined 2 Apps at GitHub and 2 Vault paths. Both paths read as not found."
