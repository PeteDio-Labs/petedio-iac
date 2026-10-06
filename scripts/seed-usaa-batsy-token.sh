#!/usr/bin/env bash
# seed-usaa-batsy-token.sh — mint the bearer that opens the usaa app's
# POST /api/v1/totals, and store it in kv/services/usaa as batsy_bearer_token (PET-590).
#
# WHY ITS OWN TOKEN. Batsy sends USAA balances and period totals to that one endpoint, and
# nothing else accepts this token. A leaked copy can post totals and cannot read the ledger.
#
# WHY A PATCH. kv/services/usaa may hold other app fields. `vault kv patch` writes this one
# field and keeps the others as they are. A first seed of an absent path uses `put`.
#
# THE ORDER, on a first seed and on a rotation:
#   1. this script
#   2. ./scripts/deploy-usaa.sh, so the app accepts the token
#   3. Pedro places the token in Batsy. No session does.
# After a rotation, Batsy holds a token the app refuses until step 3 finishes.
#
#   Vault token: $VAULT_TOKEN, else the macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM.
#   This script never prompts for it, and it never prints the bearer.
#
# Usage:
#   ./scripts/seed-usaa-batsy-token.sh            # mint one when absent, else keep it
#   ./scripts/seed-usaa-batsy-token.sh --rotate   # replace it
set -euo pipefail
umask 077

ROTATE=0
for arg in "$@"; do
  case "$arg" in
    --rotate) ROTATE=1 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PATH_KV="kv/services/usaa"
FIELD="batsy_bearer_token"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$REPO_ROOT/environments/homelab/vault-ca.crt}"

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }

for t in vault python3; do command -v "$t" >/dev/null || die "$t not in PATH."; done

step "Vault"
if [ -z "${VAULT_TOKEN:-}" ] && command -v security >/dev/null; then
  VAULT_TOKEN="$(security find-generic-password -s "$VAULT_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null || true)"
fi
[ -n "${VAULT_TOKEN:-}" ] \
  || die "no VAULT_TOKEN and no Keychain item '$VAULT_TOKEN_KEYCHAIN_ITEM'. Export VAULT_TOKEN, then run this again."
export VAULT_TOKEN
vault token lookup >/dev/null 2>&1 \
  || die "the Vault token is invalid, or Vault is sealed. Run scripts/pet-secrets doctor."
echo "  reachable, and the token is valid"

# field NAME, from the JSON in $SNAPSHOT. The value reaches python through the environment,
# never argv, and returns on stdout into a variable. Nothing here prints it.
field(){ SNAPSHOT="$SNAPSHOT" python3 -c '
import json, os, sys
try:
    d = json.loads(os.environ["SNAPSHOT"])["data"]["data"] or {}
except Exception:
    d = {}
print(d.get(sys.argv[1], ""))' "$1"; }
names(){ SNAPSHOT="$SNAPSHOT" python3 -c '
import json, os
try:
    d = json.loads(os.environ["SNAPSHOT"])["data"]["data"] or {}
except Exception:
    d = {}
print(" ".join(sorted(d)))'; }
# version prints the version $SNAPSHOT holds, or `deleted` when that version is soft-deleted.
version(){ SNAPSHOT="$SNAPSHOT" python3 -c '
import json, os
d = json.loads(os.environ["SNAPSHOT"])["data"]
print("deleted" if d.get("data") is None else d["metadata"]["version"])'; }
oneline(){ printf '%s' "$1" | tr -s '\n\t' '  ' | cut -c1-240; }

step "Read $PATH_KV"
# Only Vault's "No value found" answer proves the path absent. A 403, a timeout or a sealed
# Vault is a fault, and a `put` after it would drop every field the token cannot see. So
# the script stops on a fault, and the write below is check-and-set against VERSION.
if SNAPSHOT="$(vault kv get -format=json "$PATH_KV" 2>/dev/null)"; then
  VERSION="$(version)" || die "could not parse the read of $PATH_KV."
elif ERR="$(vault kv metadata get "$PATH_KV" 2>&1 >/dev/null)"; then
  die "$PATH_KV has metadata, but the token cannot read its data. Check the token's policy."
else
  case "$ERR" in
    "No value found at "*) VERSION=0; SNAPSHOT='{}' ;;
    *) die "Vault failed the read of $PATH_KV, so nothing was written: $(oneline "$ERR")" ;;
  esac
fi
case "$VERSION" in
  0) echo "  absent" ;;
  deleted) die "the current version of $PATH_KV is deleted. Undelete or destroy it by hand, then run this again." ;;
  [1-9]*) echo "  present at version $VERSION, fields: $(names)" ;;
  *) die "unrecognized version for $PATH_KV: $VERSION" ;;
esac
BEFORE="$(names)"
CURRENT="$(field "$FIELD")"

if [ -n "$CURRENT" ] && [ "$ROTATE" = "0" ]; then
  echo "  $FIELD: present, ${#CURRENT} characters. Kept (--rotate replaces it)."
  unset CURRENT SNAPSHOT
  exit 0
fi

step "Mint and write $FIELD"
NEW="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
[ "$NEW" != "$CURRENT" ] || die "the minted token repeats the stored one. Run this again."
# key=- reads the value from stdin, so it never reaches argv. -cas=0 creates only, and
# -cas=VERSION fails when another writer changed the path since the read.
case "$VERSION" in
  0) printf '%s' "$NEW" | vault kv put -cas=0 "$PATH_KV" "$FIELD=-" >/dev/null \
       || die "vault kv put failed for $PATH_KV. If another writer created it, run this again." ;;
  [1-9]*) printf '%s' "$NEW" | vault kv patch -cas="$VERSION" "$PATH_KV" "$FIELD=-" >/dev/null \
       || die "vault kv patch failed for $PATH_KV. If another writer changed it, run this again." ;;
  *) die "unrecognized version for $PATH_KV: $VERSION" ;;
esac

step "Verify, by reading it back"
SNAPSHOT="$(vault kv get -format=json "$PATH_KV")"
[ "$(field "$FIELD")" = "$NEW" ] || die "the read-back does not match the write."
AFTER="$(names)"
for f in $BEFORE; do
  case " $AFTER " in *" $f "*) ;; *) die "the write dropped the field $f." ;; esac
done
echo "  $FIELD: ${#NEW} characters, matches the write"
echo "  fields: $AFTER"
unset NEW CURRENT SNAPSHOT

step "Done"
cat <<NOTE
  Next, in this order:
    1. ./scripts/deploy-usaa.sh, so the app accepts the token.
    2. Pedro places the token in Batsy, reading it in his own terminal with:
         vault kv get -field=$FIELD $PATH_KV
NOTE
