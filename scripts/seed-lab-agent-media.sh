#!/usr/bin/env bash
# seed-lab-agent-media.sh — give lab-agent's media assistant its two credentials (PET-869).
#
# WHAT IT WRITES. kv/services/lab-agent-media, with up to two fields:
#   mtrace_token  a copy of `token_lab-agent` from kv/services/media/dashboard, the caller
#                 bearer that `scripts/mtrace-caller-token.sh create lab-agent` mints. Without
#                 it, lab-agent offers no media route and pete-bot's DM handler stays off.
#   bazarr_key    Bazarr's API key on LXC 222. Without it, the media assistant has no subtitle
#                 tools and no subtitle action. The key comes from $BAZARR_API_KEY, or this
#                 script reads it over SSH from Bazarr's config.yaml (see BAZARR_SSH below).
# Nothing is typed or prompted for. A separate path, so pete-bot-cd reads these two values and
# never the whole mtrace secret (which holds every caller's bearer and the SSH deploy key).
#
# THE ORDER, on a first seed:
#   1. scripts/mtrace-caller-token.sh create lab-agent, then scripts/deploy-media-dash.sh
#   2. scripts/apply-vault-config.sh, so pete-bot-cd may read kv/services/lab-agent-media
#   3. this script
#   4. scripts/deploy-pete-bot.sh, or the next merge to pete-bot's main
#
# Usage:
#   ./scripts/seed-lab-agent-media.sh            # write the fields that are absent
#   ./scripts/seed-lab-agent-media.sh --rotate   # copy both sources again and replace the fields
#
# The values never appear in argv, stdout, stderr or under `set -x`: they travel in the
# environment of one python3 process and reach Vault on stdin. What prints is each field's
# length and the secret's version.
set -euo pipefail
# A caller can run `bash -x`; tracing would print the credentials read below.
set +x
umask 077

ROTATE=0
for arg in "$@"; do
  case "$arg" in
    --rotate) ROTATE=1 ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_KV="kv/services/media/dashboard"
DST_KV="kv/services/lab-agent-media"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"
# Where Bazarr's key lives. Override both when Bazarr moves.
BAZARR_SSH="${BAZARR_SSH:-root@192.168.50.222}"
BAZARR_CONFIG="${BAZARR_CONFIG:-/var/lib/bazarr/config/config.yaml}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519_ansible}"

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

step "Read $SRC_KV (the mtrace caller token)"
read_path "$SRC_KV"
case "$VERSION" in
  absent) die "$SRC_KV is absent. Run scripts/reseed-media-dash-vault.sh first." ;;
  deleted) die "the current version of $SRC_KV is deleted." ;;
esac
NEW_MTRACE="$(field token_lab-agent)"
[ -n "$NEW_MTRACE" ] \
  || die "$SRC_KV has no token_lab-agent. Run scripts/mtrace-caller-token.sh create lab-agent, then scripts/deploy-media-dash.sh, then this again."
echo "  token_lab-agent: ${#NEW_MTRACE} characters, version $VERSION"
unset SNAPSHOT

step "Bazarr's API key"
NEW_BAZARR="${BAZARR_API_KEY:-}"
if [ -n "$NEW_BAZARR" ]; then
  echo "  from \$BAZARR_API_KEY"
else
  # Bazarr keeps its key under `auth:` in config.yaml. Read the file over SSH and take that one
  # value; the file's other lines, which hold provider logins, never leave the python3 process.
  if [ -r "$SSH_KEY" ] && command -v ssh >/dev/null; then
    NEW_BAZARR="$(ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=8 "$BAZARR_SSH" "cat $BAZARR_CONFIG" 2>/dev/null | python3 -c '
import re, sys
auth = False
for line in sys.stdin:
    if re.match(r"^\S", line):
        auth = line.startswith("auth:")
        continue
    m = re.match(r"^\s+apikey:\s*[\x27\"]?([^\s\x27\"]+)", line)
    if auth and m:
        print(m.group(1)); break' || true)"
    [ -n "$NEW_BAZARR" ] && echo "  read over SSH from $BAZARR_SSH:$BAZARR_CONFIG"
  fi
fi
if [ -n "$NEW_BAZARR" ]; then
  [ "${#NEW_BAZARR}" -ge 16 ] || die "Bazarr's key is only ${#NEW_BAZARR} characters. lab-agent refuses fewer than 16. Check $BAZARR_CONFIG."
  echo "  bazarr_key: ${#NEW_BAZARR} characters"
else
  echo "  not found, so the media assistant gets no subtitle tools. Export BAZARR_API_KEY, or check"
  echo "  that $SSH_KEY exists and $BAZARR_SSH:$BAZARR_CONFIG holds an apikey under auth:, then run this again."
fi

step "Read $DST_KV"
read_path "$DST_KV"
BEFORE="$(names)"
CUR_MTRACE="$(field mtrace_token)"
CUR_BAZARR="$(field bazarr_key)"
case "$VERSION" in
  absent) echo "  absent, so this run creates it" ;;
  deleted) die "the current version of $DST_KV is deleted. Undelete or destroy it by hand, then run this again." ;;
  *) echo "  present at version $VERSION, fields: $BEFORE" ;;
esac

# Decide each field. Without --rotate an existing, different value is kept and said so.
WRITE_MTRACE="$NEW_MTRACE"; WRITE_BAZARR="$NEW_BAZARR"
if [ "$ROTATE" = 0 ]; then
  if [ -n "$CUR_MTRACE" ]; then
    [ "$CUR_MTRACE" = "$NEW_MTRACE" ] || echo "  mtrace_token is present and differs from $SRC_KV. Kept; pass --rotate to replace it."
    WRITE_MTRACE="$CUR_MTRACE"
  fi
  if [ -n "$CUR_BAZARR" ]; then
    { [ -z "$NEW_BAZARR" ] || [ "$CUR_BAZARR" = "$NEW_BAZARR" ]; } || echo "  bazarr_key is present and differs from the source. Kept; pass --rotate to replace it."
    WRITE_BAZARR="$CUR_BAZARR"
  fi
else
  # --rotate with no new Bazarr key keeps the stored one rather than deleting it.
  [ -n "$WRITE_BAZARR" ] || WRITE_BAZARR="$CUR_BAZARR"
fi
if [ "$VERSION" != absent ] && [ "$WRITE_MTRACE" = "$CUR_MTRACE" ] && [ "$WRITE_BAZARR" = "$CUR_BAZARR" ]; then
  echo "  nothing to change."
  exit 0
fi

step "Write $DST_KV"
payload(){ M="$WRITE_MTRACE" B="$WRITE_BAZARR" python3 -c '
import json, os
d = {"mtrace_token": os.environ["M"]}
if os.environ["B"]:
    d["bazarr_key"] = os.environ["B"]
print(json.dumps(d))'; }
if [ "$VERSION" = absent ]; then
  payload | vault kv put -cas=0 "$DST_KV" - >/dev/null \
    || die "vault kv put failed for $DST_KV. If another writer created it, run this again."
else
  payload | vault kv patch -cas="$VERSION" "$DST_KV" - >/dev/null \
    || die "vault kv patch failed for $DST_KV. If another writer changed it, run this again."
fi

step "Verify, by reading it back"
SNAPSHOT="$(vault kv get -format=json "$DST_KV")"
[ "$(field mtrace_token)" = "$WRITE_MTRACE" ] || die "the read-back of mtrace_token does not match the write."
if [ -n "$WRITE_BAZARR" ]; then
  [ "$(field bazarr_key)" = "$WRITE_BAZARR" ] || die "the read-back of bazarr_key does not match the write."
fi
AFTER="$(names)"
for f in $BEFORE; do
  case " $AFTER " in *" $f "*) ;; *) die "the write dropped the field $f." ;; esac
done
echo "  mtrace_token: ${#WRITE_MTRACE} characters${WRITE_BAZARR:+; bazarr_key: ${#WRITE_BAZARR} characters}. Fields: $AFTER"
unset WRITE_MTRACE WRITE_BAZARR NEW_MTRACE NEW_BAZARR CUR_MTRACE CUR_BAZARR SNAPSHOT

step "Done"
cat <<'NOTE'
  Next: run scripts/deploy-pete-bot.sh, or merge the next change to pete-bot's main.
  Proof: DM the bot "what is in the queue". The answer ends with "read: list_queue".
NOTE
