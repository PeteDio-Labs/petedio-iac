#!/usr/bin/env bash
# seed-secrets-register.sh — copy pete-bot's notify bearer token to kv/services/secrets-register,
# field `notify_bearer_token` (PET-685).
#
# WHY A COPY. The nightly secrets-register job DMs Pedro when it fails, through pete-bot's
# POST /v1/notify. Its Vault role reads kv/services/secrets-register and KV metadata, and
# nothing else. Vault cannot scope a read to one field of kv/services/pete-bot, and that path
# also holds the Discord token and the merge desk's App key. So the job reads a copy of the
# one token that opens /v1/notify and no other route.
#
# THE ORDER:
#   1. scripts/apply-vault-config.sh, so the secrets-register role and policy exist
#   2. this script
#   3. run the secrets-register workflow once with workflow_dispatch
# A run before step 2 still checks the register. Only its DM step has no token, and it says so.
#
# A ROTATION of pete-bot's token: run this with --refresh to copy the new value.
#
#   Vault token: $VAULT_TOKEN, else the macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM.
#   This script never prompts for it, and it never prints the password.
#
# Usage:
#   ./scripts/seed-secrets-register.sh            # copy when absent, else keep it
#   ./scripts/seed-secrets-register.sh --refresh  # copy again after pete-bot's token changed
set -euo pipefail
umask 077

REFRESH=0
for arg in "$@"; do
  case "$arg" in
    --refresh) REFRESH=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="kv/services/pete-bot"
DEST="kv/services/secrets-register"
FIELD="notify_bearer_token"
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
VALUE="$(field "$FIELD")"
[ -n "$VALUE" ] || die "$SRC has no $FIELD field (fields: $(names))."
echo "  $FIELD: ${#VALUE} characters (fields at the source: $(names))"

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
CURRENT="$(field "$FIELD")"

if [ -n "$CURRENT" ]; then
  if [ "$CURRENT" = "$VALUE" ]; then
    echo "  $FIELD: already matches the source. Nothing to do."
    unset VALUE CURRENT SNAPSHOT
    exit 0
  fi
  [ "$REFRESH" = "1" ] \
    || die "$DEST holds a different $FIELD than $SRC. Run this with --refresh to copy the source again."
fi

step "Write $DEST"
# key=- reads the value from stdin, so it never reaches argv. -cas=0 creates only. A path
# that exists without the field is patched, keeping its other fields, and the write fails
# when another writer changed the path since the read.
case "$VERSION" in
  0) printf '%s' "$VALUE" | vault kv put -cas=0 "$DEST" "$FIELD"=- >/dev/null \
       || die "vault kv put failed for $DEST. If another writer created it, run this again." ;;
  [1-9]*) printf '%s' "$VALUE" | vault kv patch -cas="$VERSION" "$DEST" "$FIELD"=- >/dev/null \
       || die "vault kv patch failed for $DEST. If another writer changed it, run this again." ;;
  *) die "unrecognized version for $DEST: $VERSION" ;;
esac

step "Verify, by reading it back"
SNAPSHOT="$(vault kv get -format=json "$DEST")"
[ "$(field "$FIELD")" = "$VALUE" ] || die "the read-back does not match the source."
AFTER="$(names)"
for f in $BEFORE; do
  case " $AFTER " in *" $f "*) ;; *) die "the write dropped the field $f." ;; esac
done
echo "  $FIELD: ${#VALUE} characters, matches the source"
echo "  fields: $AFTER"
unset VALUE CURRENT SNAPSHOT

step "Done"
cat <<'NOTE'
  Next: run the secrets-register workflow once with workflow_dispatch, and read the run's last
  lines. They say how many register entries and Vault paths it examined.
NOTE
