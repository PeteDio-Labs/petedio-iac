#!/usr/bin/env bash
# retire-claude-loop-vault.sh — permanently delete kv/services/claude-loop, the GitHub App
# identity of the retired work loop (PET-399, retired by PET-547).
#
# RUN IT AFTER THE APP IS GONE AT GITHUB. Deleting petedio-claude-loop at GitHub revokes its
# key. This script removes the copy in Vault: every version and the metadata, so no
# `vault kv undelete` or rollback can restore it. It refuses while GitHub still answers for
# the App, because a live App with no key in Vault is an identity nobody can rotate.
#
# WHY A SCRIPT. A credential change is never made by hand in this lab (PET-511). Pedro runs
# this from the Mac, and the script says what it examined and verifies the result.
#
# WHAT THIS DOES NOT DO. It does not touch kv/services/plane: CI still reads that PAT. It does
# not change a policy: environments/homelab/vault-config stopped granting the path in PET-547.
#
#   Vault token: $VAULT_TOKEN, else macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM. No
#   interactive prompt — set one of those first, or this refuses to run.
#
# Usage:
#   ./scripts/retire-claude-loop-vault.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"
KV_PATH="kv/services/claude-loop"
APP_SLUG="petedio-claude-loop"

die()  { printf '\033[31mERROR\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

for t in vault gh; do command -v "$t" >/dev/null || die "$t not in PATH"; done

# ------------------------------------------------------------------- github
step "Asking GitHub whether the $APP_SLUG App still exists"
# ⚠ ASK AS AN ORG OWNER, NEVER ANONYMOUSLY. GET /apps/<slug> answers 404 to an anonymous
# request for a PRIVATE App that exists. On 2026-09-30 anonymous curl said 404 while `gh api`
# returned the App, id 4918687. So this asks through gh, and first proves the token can see a
# private App at all: CONTROL_SLUG is a private App that must exist. Without that control, a
# token with no view of the org's Apps reads every App as deleted.
CONTROL_SLUG="${CONTROL_SLUG:-petedio-code-247}"
gh api "/apps/$CONTROL_SLUG" --jq .id >/dev/null 2>&1 || die "gh cannot see the private App
  $CONTROL_SLUG, so a 404 for $APP_SLUG would prove nothing. Examined nothing. Check
  \`gh auth status\` names an owner of PeteDio-Labs, then re-run."
echo "  control: gh sees the private App $CONTROL_SLUG."
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

# -------------------------------------------------------------------- vault
step "Authenticating to Vault"
[ -f "$VAULT_CACERT" ] || die "VAULT_CACERT not found at '$VAULT_CACERT'.
  Run the script from inside the repo (./scripts/retire-claude-loop-vault.sh), or export
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
  if out="$(vault kv metadata get "$KV_PATH" 2>&1)"; then
    echo present
  elif printf '%s' "$out" | grep -q 'No value found at'; then
    echo absent
  else
    die "Could not read the metadata at $KV_PATH. Vault said:
  $out"
  fi
}

step "Reading $KV_PATH"
BEFORE="$(kv_state)"
case "$BEFORE" in
  absent)
    echo "  $KV_PATH is already absent. Nothing to delete."
    exit 0 ;;
  present)
    echo "  $KV_PATH exists. Deleting every version and the metadata." ;;
  *) die "unexpected state '$BEFORE' for $KV_PATH" ;;
esac

vault kv metadata delete "$KV_PATH" >/dev/null || die "vault kv metadata delete $KV_PATH failed."

step "Verifying"
AFTER="$(kv_state)"
case "$AFTER" in
  absent)  echo "  $KV_PATH reads as not found. Verified." ;;
  present) die "$KV_PATH still has metadata after the delete. Read it with:
  vault kv metadata get $KV_PATH" ;;
  *)       die "unexpected state '$AFTER' for $KV_PATH" ;;
esac
