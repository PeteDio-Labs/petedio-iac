#!/usr/bin/env bash
# seed-usaa-calendar-url.sh — store the Finance calendar's secret iCal address in
# kv/services/usaa as calendar_ics_url, for the usaa app's month view (PET-590).
#
# WHAT THE ADDRESS IS. Google Calendar → Settings → the Finance calendar → Integrate
# calendar → "Secret address in iCal format". Anyone holding it reads every event, so it is
# a secret. The app reads it every hour and never logs it.
#
# HOW IT ARRIVES. The script prompts for it with echo off, so it never reaches argv, the
# shell history or the terminal. It checks the shape (https, no space or quote) before it
# writes, and it never prints the value.
#
# WHY A PATCH. kv/services/usaa holds the agents' tokens. `vault kv patch` writes this one
# field and keeps the others. A first seed of an absent path uses `put`.
#
# THE ORDER:
#   1. this script, run by Pedro
#   2. ./scripts/deploy-usaa.sh, so the app reads the calendar
# To revoke the address, reset it in Google Calendar, then run this again with the new one.
#
#   Vault token: $VAULT_TOKEN, else the macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM.
#
# Usage:
#   ./scripts/seed-usaa-calendar-url.sh
set -euo pipefail
umask 077

case "${1:-}" in
  "") ;;
  -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
  *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PATH_KV="kv/services/usaa"
FIELD="calendar_ics_url"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$REPO_ROOT/environments/homelab/vault-ca.crt}"

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }

for t in vault python3; do command -v "$t" >/dev/null || die "$t not in PATH."; done
[ -t 0 ] || die "run this in a terminal: it prompts for the address with echo off."

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

# The same readers as seed-usaa-batsy-token.sh: values travel through the environment,
# never argv, and nothing here prints one.
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
version(){ SNAPSHOT="$SNAPSHOT" python3 -c '
import json, os
d = json.loads(os.environ["SNAPSHOT"])["data"]
print("deleted" if d.get("data") is None else d["metadata"]["version"])'; }
oneline(){ printf '%s' "$1" | tr -s '\n\t' '  ' | cut -c1-240; }

step "Read $PATH_KV"
# Only "No value found" proves the path absent. Any other failure stops the script, and the
# write below is check-and-set against VERSION.
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
[ -z "$CURRENT" ] || echo "  $FIELD: present. The address you enter replaces it."

step "Enter the address"
printf '  Paste the secret address in iCal format, then press Enter (input hidden): '
IFS= read -rs NEW
printf '\n'
# The env file holds it single-quoted, so the shape check matches the playbook's assert.
python3 -c '
import os, re, sys
v = os.environ["NEW"]
if not re.fullmatch(r"https://[A-Za-z0-9._~:/?#@!$&()*+,;=%-]+", v):
    sys.exit("the address must start with https:// and hold no space or quote.")
if not v.endswith(".ics"):
    sys.exit("the address should end in .ics. Copy the iCal address, not the public or embed link.")
' || die "nothing was written."
[ "$NEW" != "$CURRENT" ] || { echo "  unchanged: the stored address is the same."; exit 0; }

step "Write $FIELD"
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
echo "  Next: ./scripts/deploy-usaa.sh, so the app reads the calendar."
