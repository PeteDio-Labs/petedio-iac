#!/usr/bin/env bash
# seed-lab-agent-search.sh — give lab-agent's search_lab tool its petedio-search token (PET-745).
#
# WHAT IT WRITES. kv/services/lab-agent-search, field `token`: a copy of `token_lab-agent` from
# kv/services/search, the caller bearer that `search-secrets.sh create lab-agent` mints. Nothing
# is typed or prompted for. A separate path, so pete-bot-cd reads this one token and never the
# whole search secret (which holds every caller's bearer and the Plane key). An absent path just
# leaves search_lab off.
#
# THE ORDER, on a first seed:
#   1. scripts/search-secrets.sh create lab-agent, then scripts/deploy-search.sh
#   2. scripts/apply-vault-config.sh, so pete-bot-cd may read kv/services/lab-agent-search
#   3. this script
#   4. scripts/deploy-pete-bot.sh, or the next merge to pete-bot's main
#
# Usage:
#   ./scripts/seed-lab-agent-search.sh            # write the token when the path is absent
#   ./scripts/seed-lab-agent-search.sh --rotate   # copy the search secret's current token again
set -euo pipefail
umask 077

ROTATE=0
for arg in "$@"; do
  case "$arg" in
    --rotate) ROTATE=1 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_KV="kv/services/search"
DST_KV="kv/services/lab-agent-search"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$REPO_ROOT/environments/homelab/vault-ca.crt}"

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }
oneline(){ printf '%s' "$1" | tr -s '\n\t' '  ' | cut -c1-240; }

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

# field NAME reads the JSON in $SNAPSHOT. The value returns on stdout into a variable only.
field(){ SNAPSHOT="${SNAPSHOT:-}" python3 -c '
import json, os, sys
try:
    d = json.loads(os.environ["SNAPSHOT"])["data"]["data"] or {}
except Exception:
    d = {}
print(d.get(sys.argv[1], ""))' "$1"; }
names(){ SNAPSHOT="${SNAPSHOT:-}" python3 -c '
import json, os
try:
    d = json.loads(os.environ["SNAPSHOT"])["data"]["data"] or {}
except Exception:
    d = {}
print(" ".join(sorted(d)))'; }
version(){ SNAPSHOT="$SNAPSHOT" python3 -c '
import json, os
d = json.loads(os.environ["SNAPSHOT"])["data"]
print("deleted" if d.get("data") is None else d["metadata"]["version"])'; }

# read_path PATH sets SNAPSHOT and VERSION. Only Vault's "No value found" proves a path
# absent (VERSION=absent). A 403, a timeout or a sealed Vault stops the script.
read_path(){
  local path="$1" err
  SNAPSHOT=""
  if SNAPSHOT="$(vault kv get -format=json "$path" 2>/dev/null)"; then
    VERSION="$(version)" || die "could not parse the read of $path."
  elif vault kv metadata get "$path" >/dev/null 2>&1; then
    die "$path has metadata, but the token cannot read its data (or its current version is deleted)."
  else
    err="$(vault kv metadata get "$path" 2>&1 >/dev/null || true)"
    case "$err" in
      "No value found at "*) VERSION=absent; SNAPSHOT="" ;;
      *) die "Vault failed the read of $path, so nothing was written: $(oneline "$err")" ;;
    esac
  fi
}

step "Read $SRC_KV"
read_path "$SRC_KV"
case "$VERSION" in
  absent) die "$SRC_KV is absent. Run scripts/search-secrets.sh create lab-agent first." ;;
  deleted) die "the current version of $SRC_KV is deleted." ;;
esac
NEW="$(field token_lab-agent)"
[ -n "$NEW" ] || die "$SRC_KV has no token_lab-agent (fields: $(names | tr ' ' '\n' | grep -v '^token_' | tr '\n' ' '), and the caller names are hidden). Run scripts/search-secrets.sh create lab-agent."
echo "  token_lab-agent: ${#NEW} characters, version $VERSION"
unset SNAPSHOT

step "Read $DST_KV"
read_path "$DST_KV"
BEFORE="$(names)"
CUR="$(field token)"
case "$VERSION" in
  absent) echo "  absent, so this run creates it" ;;
  deleted) die "the current version of $DST_KV is deleted. Undelete or destroy it by hand, then run this again." ;;
  *) echo "  present at version $VERSION, fields: $BEFORE" ;;
esac
if [ "$VERSION" != absent ] && [ -n "$CUR" ] && [ "$ROTATE" = 0 ]; then
  [ "$CUR" = "$NEW" ] && echo "  token already matches $SRC_KV. Nothing to write." \
    || echo "  token is present and differs from $SRC_KV. Kept; pass --rotate to replace it."
  exit 0
fi
[ "$ROTATE" = 0 ] || [ "$CUR" != "$NEW" ] || { echo "  token already matches $SRC_KV. Nothing to write."; exit 0; }

step "Write $DST_KV"
payload(){ NEW="$NEW" python3 -c 'import json, os; print(json.dumps({"token": os.environ["NEW"]}))'; }
if [ "$VERSION" = absent ]; then
  payload | vault kv put -cas=0 "$DST_KV" - >/dev/null \
    || die "vault kv put failed for $DST_KV. If another writer created it, run this again."
else
  payload | vault kv patch -cas="$VERSION" "$DST_KV" - >/dev/null \
    || die "vault kv patch failed for $DST_KV. If another writer changed it, run this again."
fi

step "Verify, by reading it back"
SNAPSHOT="$(vault kv get -format=json "$DST_KV")"
[ "$(field token)" = "$NEW" ] || die "the read-back of token does not match the write."
AFTER="$(names)"
for f in $BEFORE; do
  case " $AFTER " in *" $f "*) ;; *) die "the write dropped the field $f." ;; esac
done
echo "  token: ${#NEW} characters, matches the write. Fields: $AFTER"
unset NEW CUR SNAPSHOT

step "Done"
cat <<'NOTE'
  Next: run scripts/deploy-pete-bot.sh, or merge the next change to pete-bot's main.
  Proof: ask /lab "where is the runbook for restoring vzdump archives". The answer cites a search_lab ref.
NOTE
