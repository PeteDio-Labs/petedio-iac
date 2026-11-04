#!/usr/bin/env bash
# seed-postgres-admin-vault.sh — copy the Postgres server-admin password from kv/poker/db
# to kv/admin/postgres, field `admin_password` (PET-691).
#
# WHY. The postgresql provider authenticates with a SERVER-WIDE admin credential that has
# lived at kv/poker/db since before Co-latro was removed (PET-366). The path name is a trap,
# and the policies that grant it (kv/poker/*) are the last reason that prefix exists.
# postgres.tf now reads kv/admin/postgres. This script copies one field, `admin_password`.
# It leaves kv/poker/db untouched, so a rollback is a revert of the PR.
#
# THE ORDER (a plan reads the new path at plan time, as ci-read):
#   1. scripts/apply-vault-config.sh, so ci-read and terraform can read kv/data/admin/postgres
#      (the PET-691 policy change keeps the kv/poker/* grants, so the old path still works)
#   2. this script
#   3. Pedro merges the petedio-iac PR whose postgres.tf reads kv/admin/postgres
#   4. a follow-up PR retires the kv/poker/* grants, after a plan has read the new path
# Step 3 before steps 1 and 2 fails the apply on a path ci-read cannot read or that is absent.
#
#   Vault token: $VAULT_TOKEN, else the macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM.
#   This script never prompts for it, and it never prints the password.
#
# Usage:
#   ./scripts/seed-postgres-admin-vault.sh
set -euo pipefail
umask 077

for arg in "$@"; do
  case "$arg" in
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="kv/poker/db"
DEST="kv/admin/postgres"
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
# never argv. Nothing here prints it.
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

step "Read the source $SRC"
SNAPSHOT="$(vault kv get -format=json "$SRC" 2>/dev/null)" \
  || die "could not read $SRC. Check the token's policy, and run scripts/pet-secrets doctor."
[ "$(version)" != "deleted" ] || die "the current version of $SRC is deleted."
VALUE="$(field admin_password)"
[ -n "$VALUE" ] || die "$SRC has no admin_password field (fields: $(names))."
echo "  admin_password: ${#VALUE} characters (fields at the source: $(names))"

step "Read the destination $DEST"
# Only Vault's "No value found" answer proves the path absent. A 403, a timeout or a sealed
# Vault is a fault. The write below is check-and-set against VERSION.
if SNAPSHOT="$(vault kv get -format=json "$DEST" 2>/dev/null)"; then
  VERSION="$(version)" || die "could not parse the read of $DEST."
elif ERR="$(vault kv metadata get "$DEST" 2>&1 >/dev/null)"; then
  die "$DEST has metadata, but the token cannot read its data. Check the token's policy."
else
  case "$ERR" in
    "No value found at "*) VERSION=0; SNAPSHOT='{}' ;;
    *) die "Vault failed the read of $DEST, so nothing was written: $(oneline "$ERR")" ;;
  esac
fi
case "$VERSION" in
  0) echo "  absent" ;;
  deleted) die "the current version of $DEST is deleted. Undelete or destroy it by hand, then run this again." ;;
  [1-9]*) echo "  present at version $VERSION, fields: $(names)" ;;
  *) die "unrecognized version for $DEST: $VERSION" ;;
esac
BEFORE="$(names)"
CURRENT="$(field admin_password)"

if [ -n "$CURRENT" ]; then
  [ "$CURRENT" = "$VALUE" ] \
    || die "$DEST holds a different admin_password than $SRC. This script does not overwrite it. Decide which is live, then fix one by hand."
  echo "  admin_password: already matches the source. Nothing to do."
  unset VALUE CURRENT SNAPSHOT
  exit 0
fi

step "Write $DEST"
# key=- reads the value from stdin, so it never reaches argv. -cas=0 creates only. A path
# that exists without the field is patched, keeping its other fields, and the write fails
# when another writer changed the path since the read.
case "$VERSION" in
  0) printf '%s' "$VALUE" | vault kv put -cas=0 "$DEST" admin_password=- >/dev/null \
       || die "vault kv put failed for $DEST. If another writer created it, run this again." ;;
  [1-9]*) printf '%s' "$VALUE" | vault kv patch -cas="$VERSION" "$DEST" admin_password=- >/dev/null \
       || die "vault kv patch failed for $DEST. If another writer changed it, run this again." ;;
  *) die "unrecognized version for $DEST: $VERSION" ;;
esac

step "Verify, by reading it back"
SNAPSHOT="$(vault kv get -format=json "$DEST")"
[ "$(field admin_password)" = "$VALUE" ] || die "the read-back does not match the source."
AFTER="$(names)"
for f in $BEFORE; do
  case " $AFTER " in *" $f "*) ;; *) die "the write dropped the field $f." ;; esac
done
echo "  admin_password: ${#VALUE} characters, matches the source"
echo "  fields: $AFTER"
unset VALUE CURRENT SNAPSHOT

step "Done"
cat <<'NOTE'
  Next: ./scripts/vault-verify.sh, then Pedro merges the petedio-iac PR whose postgres.tf
  reads kv/admin/postgres. A plan on environments/homelab must show no change to Postgres.
  kv/poker/db stays until the follow-up PR retires the kv/poker/* grants.
NOTE
