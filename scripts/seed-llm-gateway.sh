#!/usr/bin/env bash
# seed-llm-gateway.sh — store the Anthropic API key and pm-agent's gateway bearer in
# kv/services/pete-bot, as anthropic_api_key and gateway_token_pm_agent (PET-617).
#
# WHAT THEY OPEN. pete-bot's gateway on 237 holds the homelab's one Anthropic key and
# forwards POST /v1/llm/v1/messages with it. Each caller sends its own bearer, and the
# gateway caps its monthly spend. pm-agent is the first caller. No caller holds the key.
#
# WHERE THE VALUES COME FROM. Pedro mints the key in the Anthropic Console and pastes it
# at this script's hidden prompt, or pipes it on stdin. The script mints the bearer. The
# Vault token is never prompted for: $VAULT_TOKEN, else the macOS Keychain item
# $VAULT_TOKEN_KEYCHAIN_ITEM. Nothing here prints a value.
#
# WHY A PATCH. kv/services/pete-bot also holds the Discord token and the other bearers.
# `vault kv patch -cas=<version>` writes these two fields, keeps the rest, and fails when
# another writer changed the path after this script read it.
#
# THE ORDER, on a first seed:
#   1. pete-bot#30 merged, so the deployed binary has the gateway
#   2. this script
#   3. scripts/deploy-pete-bot.sh, or pete-bot's deploy.yml PR that reads both fields.
#      That PR merges only after step 2: its Vault step fails on a missing field.
#   4. pm-agent's bearer reaches 247 with the pm-agent timer PR, not before.
# A rotation of either field runs steps 3 and 4 again.
#
# Usage:
#   ./scripts/seed-llm-gateway.sh                  # write whichever field is absent
#   ./scripts/seed-llm-gateway.sh --rotate-key     # replace the Anthropic key
#   ./scripts/seed-llm-gateway.sh --rotate-token   # replace pm-agent's bearer
#   printf '%s' "$KEY" | ./scripts/seed-llm-gateway.sh --rotate-key   # key on stdin
set -euo pipefail
umask 077

ROTATE_KEY=0
ROTATE_TOKEN=0
for arg in "$@"; do
  case "$arg" in
    --rotate-key) ROTATE_KEY=1 ;;
    --rotate-token) ROTATE_TOKEN=1 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PATH_KV="kv/services/pete-bot"
KEY_FIELD="anthropic_api_key"
TOKEN_FIELD="gateway_token_pm_agent"
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
# others prints a digest of every field but these two, so the read-back can prove the
# patch left them as they were without holding or printing their values.
others(){ SNAPSHOT="$SNAPSHOT" python3 -c '
import hashlib, json, os, sys
d = json.loads(os.environ["SNAPSHOT"])["data"]["data"] or {}
rest = {k: v for k, v in d.items() if k not in sys.argv[1:]}
print(hashlib.sha256(json.dumps(rest, sort_keys=True).encode()).hexdigest())' "$KEY_FIELD" "$TOKEN_FIELD"; }
# reused VALUE-ENV-NAME exits 0 when any field but the bearer's own holds that value.
reused(){ SNAPSHOT="$SNAPSHOT" python3 -c '
import json, os, sys
d = json.loads(os.environ["SNAPSHOT"])["data"]["data"] or {}
v = os.environ[sys.argv[1]]
sys.exit(0 if any(val == v for k, val in d.items() if k != sys.argv[2]) else 1)' "$1" "$TOKEN_FIELD"; }
# version prints the version $SNAPSHOT holds, or `deleted` when that version is soft-deleted.
version(){ SNAPSHOT="$SNAPSHOT" python3 -c '
import json, os
d = json.loads(os.environ["SNAPSHOT"])["data"]
print("deleted" if d.get("data") is None else d["metadata"]["version"])'; }
oneline(){ printf '%s' "$1" | tr -s '\n\t' '  ' | cut -c1-240; }

step "Read $PATH_KV"
# Only Vault's "No value found" answer proves the path absent. A 403, a timeout or a sealed
# Vault is a fault. This path must already exist, so absent is a stop too.
if SNAPSHOT="$(vault kv get -format=json "$PATH_KV" 2>/dev/null)"; then
  VERSION="$(version)" || die "could not parse the read of $PATH_KV."
elif ERR="$(vault kv metadata get "$PATH_KV" 2>&1 >/dev/null)"; then
  die "$PATH_KV has metadata, but the token cannot read its data. Check the token's policy."
else
  case "$ERR" in
    "No value found at "*) die "$PATH_KV is absent. Run scripts/seed-pete-bot-vault.sh first." ;;
    *) die "Vault failed the read of $PATH_KV, so nothing was written: $(oneline "$ERR")" ;;
  esac
fi
case "$VERSION" in
  deleted) die "the current version of $PATH_KV is deleted. Undelete or destroy it by hand, then run this again." ;;
  [1-9]*) echo "  present at version $VERSION, fields: $(names)" ;;
  *) die "unrecognized version for $PATH_KV: $VERSION" ;;
esac
BEFORE="$(names)"
OTHERS="$(others)"
CUR_KEY="$(field "$KEY_FIELD")"
CUR_TOKEN="$(field "$TOKEN_FIELD")"

WRITE_KEY=0
WRITE_TOKEN=0
if [ -n "$CUR_KEY" ] && [ "$ROTATE_KEY" = "0" ]; then
  echo "  $KEY_FIELD: present, ${#CUR_KEY} characters. Kept (--rotate-key replaces it)."
else
  WRITE_KEY=1
fi
if [ -n "$CUR_TOKEN" ] && [ "$ROTATE_TOKEN" = "0" ]; then
  echo "  $TOKEN_FIELD: present, ${#CUR_TOKEN} characters. Kept (--rotate-token replaces it)."
else
  WRITE_TOKEN=1
fi
if [ "$WRITE_KEY" = "0" ] && [ "$WRITE_TOKEN" = "0" ]; then
  unset CUR_KEY CUR_TOKEN SNAPSHOT
  exit 0
fi

NEW_KEY="$CUR_KEY"
NEW_TOKEN="$CUR_TOKEN"

if [ "$WRITE_KEY" = "1" ]; then
  step "Read the Anthropic key"
  # The key is the one value a person supplies, so it is read here: hidden on a terminal,
  # or one line on stdin. Either way it stays out of argv and the shell history.
  if [ -t 0 ]; then
    read -rsp "  Paste the Anthropic API key (input hidden): " NEW_KEY; echo
  else
    IFS= read -r NEW_KEY || [ -n "$NEW_KEY" ] || die "no key on stdin."
  fi
  NEW_KEY="${NEW_KEY%$'\r'}"
  [[ "$NEW_KEY" =~ ^sk-ant-[A-Za-z0-9_-]{20,}$ ]] \
    || die "that is not an Anthropic API key (sk-ant-…), so nothing was written."
  [ "$NEW_KEY" != "$CUR_KEY" ] || die "that key is the one already stored, so nothing was written."
  echo "  ${#NEW_KEY} characters, shaped like an API key"
fi

if [ "$WRITE_TOKEN" = "1" ]; then
  step "Mint $TOKEN_FIELD"
  NEW_TOKEN="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
  [ "$NEW_TOKEN" != "$CUR_TOKEN" ] || die "the minted bearer repeats the stored one. Run this again."
  # The gateway refuses a bearer that opens another route, so refuse it here first.
  if NEW_TOKEN="$NEW_TOKEN" reused NEW_TOKEN; then
    die "the minted bearer repeats another field. Run this again."
  fi
  echo "  ${#NEW_TOKEN} characters"
fi

step "Write $PATH_KV"
# JSON on stdin (the trailing `-`), so neither value reaches argv. -cas=VERSION fails when
# another writer changed the path since the read. patch keeps every other field.
NEW_KEY="$NEW_KEY" NEW_TOKEN="$NEW_TOKEN" python3 -c '
import json, os, sys
print(json.dumps({sys.argv[1]: os.environ["NEW_KEY"], sys.argv[2]: os.environ["NEW_TOKEN"]}))' \
  "$KEY_FIELD" "$TOKEN_FIELD" \
  | vault kv patch -cas="$VERSION" "$PATH_KV" - >/dev/null \
  || die "vault kv patch failed for $PATH_KV. If another writer changed it, run this again."

step "Verify, by reading it back"
SNAPSHOT="$(vault kv get -format=json "$PATH_KV")"
[ "$(field "$KEY_FIELD")" = "$NEW_KEY" ] || die "the read-back of $KEY_FIELD does not match the write."
[ "$(field "$TOKEN_FIELD")" = "$NEW_TOKEN" ] || die "the read-back of $TOKEN_FIELD does not match the write."
[ "$(others)" = "$OTHERS" ] || die "the patch changed a field other than these two."
AFTER="$(names)"
for f in $BEFORE; do
  case " $AFTER " in *" $f "*) ;; *) die "the patch dropped the field $f." ;; esac
done
echo "  $KEY_FIELD: ${#NEW_KEY} characters, matches$([ "$WRITE_KEY" = 1 ] && echo ' the write' || echo ', kept')"
echo "  $TOKEN_FIELD: ${#NEW_TOKEN} characters, matches$([ "$WRITE_TOKEN" = 1 ] && echo ' the write' || echo ', kept')"
echo "  every other field is unchanged"
echo "  fields: $AFTER"
unset NEW_KEY NEW_TOKEN CUR_KEY CUR_TOKEN SNAPSHOT

step "Done"
cat <<'NOTE'
  Next, in this order:
    1. Deploy pete-bot: ./scripts/deploy-pete-bot.sh, or merge pete-bot's deploy.yml PR
       that reads both fields. The play fails unless /health reports llm: on.
    2. pm-agent's bearer reaches 247 with the pm-agent timer PR. After a rotation of the
       bearer, run ./scripts/deploy-claude-247.sh once that PR has merged.
NOTE
