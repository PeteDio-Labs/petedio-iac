#!/usr/bin/env bash
# seed-lab-agent.sh — mint lab-agent's credentials and store them in kv/services/lab-agent
# (PET-670).
#
# WHAT IT WRITES. Five fields, none of them typed by a person:
#   ask_token             the bearer pete-bot's /lab sends to lab-agent's POST /v1/ask
#   vault_token           a periodic, orphan Vault token with the lab-agent-presence policy
#   vault_token_accessor  that token's accessor, so a rotation can revoke the old token
#   vault_deploy_key      an ed25519 key that reads PeteDio-Labs/petedio-vault, and only it
#   vault_deploy_key_pub  its public half, which Pedro adds to that repo as a deploy key
# lab-agent's read-only Proxmox token lives at kv/services/lab-agent-pve. The play
# ansible/playbooks/mint-pve-audit-token.yml mints it, because a node has to be touched.
#
# WHERE THE VALUES COME FROM. This script mints every value. The Vault token is never
# prompted for: $VAULT_TOKEN, else the macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM. It
# must be able to create an orphan token, which Pedro's root token can. Nothing here prints
# a secret; the deploy key's public half is not one.
#
# WHY CHECK-AND-SET. The first write creates the path with -cas=0, which fails if the path
# appeared since the read. Later writes patch with -cas=<version>, which keeps the other
# fields and fails when another writer changed the path after this script read it.
#
# THE ORDER, on a first seed:
#   1. scripts/apply-vault-config.sh, so the lab-agent-presence policy exists and
#      pete-bot-cd may read both lab-agent paths
#   2. ansible-playbook playbooks/mint-pve-audit-token.yml -e pve_client=lab-agent
#   3. this script, which stops for the deploy key to be added on GitHub
#   4. scripts/deploy-pete-bot.sh, or pete-bot's deploy.yml PR that reads both paths. That
#      PR merges only after steps 2 and 3: its Vault step fails on a missing field.
#
# Usage:
#   ./scripts/seed-lab-agent.sh                        # write whichever field is absent
#   ./scripts/seed-lab-agent.sh --rotate-ask           # replace the ask bearer
#   ./scripts/seed-lab-agent.sh --rotate-vault-token   # replace the Vault token, revoke the old
#   ./scripts/seed-lab-agent.sh --rotate-deploy-key    # replace the deploy key
# After any rotation, run step 4 again.
set -euo pipefail
umask 077

ROTATE_ASK=0
ROTATE_VAULT=0
ROTATE_KEY=0
for arg in "$@"; do
  case "$arg" in
    --rotate-ask) ROTATE_ASK=1 ;;
    --rotate-vault-token) ROTATE_VAULT=1 ;;
    --rotate-deploy-key) ROTATE_KEY=1 ;;
    -h|--help) sed -n '2,37p' "$0"; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PATH_KV="kv/services/lab-agent"
POLICY="lab-agent-presence"
# A week. lab-agent renews every 12 hours, so the token lapses only after lab-agent has
# been down, or Vault sealed, for most of a week.
PERIOD="168h"
VAULT_REPO="git@github.com:PeteDio-Labs/petedio-vault.git"
DEPLOY_KEY_PAGE="https://github.com/PeteDio-Labs/petedio-vault/settings/keys/new"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$REPO_ROOT/environments/homelab/vault-ca.crt}"

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }

for t in vault python3 ssh-keygen git; do command -v "$t" >/dev/null || die "$t not in PATH."; done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

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
# A token minted with a policy that does not exist yet would be refused on every read, and
# lab-agent would report it as a 403 rather than as a missing step.
vault policy read "$POLICY" >/dev/null 2>&1 \
  || die "Vault has no policy $POLICY. Run scripts/apply-vault-config.sh first."
echo "  the $POLICY policy exists"

# field NAME, from the JSON in $SNAPSHOT. The value reaches python through the environment,
# never argv, and returns on stdout into a variable. Nothing here prints it.
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
oneline(){ printf '%s' "$1" | tr -s '\n\t' '  ' | cut -c1-240; }

step "Read $PATH_KV"
# Only Vault's "No value found" answer proves the path absent. A 403, a timeout or a sealed
# Vault is a fault, and nothing is written.
SNAPSHOT=""
if SNAPSHOT="$(vault kv get -format=json "$PATH_KV" 2>/dev/null)"; then
  VERSION="$(version)" || die "could not parse the read of $PATH_KV."
elif META="$(vault kv metadata get -format=json "$PATH_KV" 2>/dev/null)"; then
  # A deleted current version also fails the data read while its metadata reads fine.
  if META="$META" python3 -c '
import json, os, sys
d = json.loads(os.environ["META"])["data"]
v = d["versions"].get(str(d["current_version"]), {})
sys.exit(0 if v.get("deletion_time") or v.get("destroyed") else 1)'; then
    die "the current version of $PATH_KV is deleted. Undelete or destroy it by hand, then run this again."
  fi
  die "$PATH_KV has metadata, but the token cannot read its data. Check the token's policy."
elif ERR="$(vault kv metadata get "$PATH_KV" 2>&1 >/dev/null)"; then
  die "Vault answered the metadata read of $PATH_KV oddly, so nothing was written."
else
  case "$ERR" in
    "No value found at "*) VERSION=absent; SNAPSHOT="" ;;
    *) die "Vault failed the read of $PATH_KV, so nothing was written: $(oneline "$ERR")" ;;
  esac
fi
case "$VERSION" in
  absent) echo "  absent, so this run creates it" ;;
  deleted) die "the current version of $PATH_KV is deleted. Undelete or destroy it by hand, then run this again." ;;
  [1-9]*) echo "  present at version $VERSION, fields: $(names)" ;;
  *) die "unrecognized version for $PATH_KV: $VERSION" ;;
esac
BEFORE="$(names)"
CUR_ASK="$(field ask_token)"
CUR_VAULT="$(field vault_token)"
CUR_ACCESSOR="$(field vault_token_accessor)"
CUR_KEY="$(field vault_deploy_key)"
CUR_PUB="$(field vault_deploy_key_pub)"

# want CURRENT ROTATE: 0 keeps the field, 1 writes it.
want(){ if [ -n "$1" ] && [ "$2" = "0" ]; then echo 0; else echo 1; fi; }
WRITE_ASK="$(want "$CUR_ASK" "$ROTATE_ASK")"
WRITE_VAULT="$(want "$CUR_VAULT" "$ROTATE_VAULT")"
WRITE_KEY="$(want "$CUR_KEY" "$ROTATE_KEY")"
# The accessor and the public half travel with their secret. One without the other is a
# path someone edited by hand, and this script writes both again.
[ -n "$CUR_ACCESSOR" ] || WRITE_VAULT=1
[ -n "$CUR_PUB" ] || WRITE_KEY=1
report(){ if [ "$2" = "0" ]; then echo "  $1: present. Kept."; else echo "  $1: will be written"; fi; }
report ask_token "$WRITE_ASK"
report vault_token "$WRITE_VAULT"
report vault_deploy_key "$WRITE_KEY"
CHECK_ONLY=0
if [ "$WRITE_ASK$WRITE_VAULT$WRITE_KEY" = "000" ]; then
  # Nothing to write, but a run that stopped at the deploy-key check comes back here, so
  # the key is still checked below before this reports success.
  echo "  nothing to write"
  CHECK_ONLY=1
fi

NEW_ASK="$CUR_ASK"
NEW_VAULT="$CUR_VAULT"
NEW_ACCESSOR="$CUR_ACCESSOR"
NEW_KEY="$CUR_KEY"
NEW_PUB="$CUR_PUB"

if [ "$CHECK_ONLY" = "0" ]; then
if [ "$WRITE_ASK" = "1" ]; then
  step "Mint the ask bearer"
  NEW_ASK="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
  [ "$NEW_ASK" != "$CUR_ASK" ] || die "the minted bearer repeats the stored one. Run this again."
  echo "  ${#NEW_ASK} characters"
fi

if [ "$WRITE_KEY" = "1" ]; then
  step "Mint the petedio-vault deploy key"
  ssh-keygen -q -t ed25519 -N '' -C "lab-agent@media-dash-237 (PET-670)" -f "$TMP/deploy" >/dev/null
  NEW_KEY="$(cat "$TMP/deploy")"
  NEW_PUB="$(cat "$TMP/deploy.pub")"
  echo "  $(ssh-keygen -lf "$TMP/deploy.pub")"
fi

if [ "$WRITE_VAULT" = "1" ]; then
  step "Mint the Vault token"
  # -orphan, so the token outlives the token that created it. -period, so it lives as long
  # as lab-agent renews it. One policy, and not the default policy's broader grants.
  vault token create -orphan -policy="$POLICY" -no-default-policy -period="$PERIOD" \
    -display-name=lab-agent -metadata=pet=PET-670 -format=json > "$TMP/token.json" \
    || die "vault token create failed, so nothing was written."
  NEW_VAULT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["auth"]["client_token"])' "$TMP/token.json")"
  NEW_ACCESSOR="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["auth"]["accessor"])' "$TMP/token.json")"
  rm -f "$TMP/token.json"
  [ -n "$NEW_VAULT" ] && [ -n "$NEW_ACCESSOR" ] || die "vault token create returned no token. Nothing was written."
  echo "  minted, period $PERIOD, accessor $NEW_ACCESSOR"
fi

step "Write $PATH_KV"
# JSON on stdin (the trailing `-`), so no value reaches argv.
payload(){ NEW_ASK="$NEW_ASK" NEW_VAULT="$NEW_VAULT" NEW_ACCESSOR="$NEW_ACCESSOR" \
  NEW_KEY="$NEW_KEY" NEW_PUB="$NEW_PUB" python3 -c '
import json, os
print(json.dumps({
    "ask_token": os.environ["NEW_ASK"],
    "vault_token": os.environ["NEW_VAULT"],
    "vault_token_accessor": os.environ["NEW_ACCESSOR"],
    "vault_deploy_key": os.environ["NEW_KEY"],
    "vault_deploy_key_pub": os.environ["NEW_PUB"],
}))'; }
revoke_new(){
  # A token minted for a write that failed is a live credential nobody holds. Revoke it.
  [ "$WRITE_VAULT" = "1" ] && vault token revoke -accessor "$NEW_ACCESSOR" >/dev/null 2>&1 || true
}
if [ "$VERSION" = "absent" ]; then
  payload | vault kv put -cas=0 "$PATH_KV" - >/dev/null \
    || { revoke_new; die "vault kv put failed for $PATH_KV. If another writer created it, run this again."; }
else
  payload | vault kv patch -cas="$VERSION" "$PATH_KV" - >/dev/null \
    || { revoke_new; die "vault kv patch failed for $PATH_KV. If another writer changed it, run this again."; }
fi

step "Verify, by reading it back"
SNAPSHOT="$(vault kv get -format=json "$PATH_KV")"
[ "$(field ask_token)" = "$NEW_ASK" ] || die "the read-back of ask_token does not match the write."
[ "$(field vault_token)" = "$NEW_VAULT" ] || die "the read-back of vault_token does not match the write."
[ "$(field vault_token_accessor)" = "$NEW_ACCESSOR" ] || die "the read-back of vault_token_accessor does not match."
[ "$(field vault_deploy_key)" = "$NEW_KEY" ] || die "the read-back of vault_deploy_key does not match the write."
[ "$(field vault_deploy_key_pub)" = "$NEW_PUB" ] || die "the read-back of vault_deploy_key_pub does not match."
AFTER="$(names)"
for f in $BEFORE; do
  case " $AFTER " in *" $f "*) ;; *) die "the write dropped the field $f." ;; esac
done
echo "  every field reads back as written: $AFTER"

# Prove the token does what lab-agent needs, and nothing more: it lists metadata under
# services/ and is refused this path's data.
VAULT_TOKEN="$NEW_VAULT" vault kv metadata get "$PATH_KV" >/dev/null 2>&1 \
  || die "the lab-agent token cannot read $PATH_KV's metadata. Check the $POLICY policy."
if VAULT_TOKEN="$NEW_VAULT" vault kv get "$PATH_KV" >/dev/null 2>&1; then
  die "the lab-agent token can read secret values. The $POLICY policy grants too much; fix it before you deploy."
fi
# lab-agent's health check lists the folder, so prove the list too.
VAULT_TOKEN="$NEW_VAULT" vault list kv/metadata/services/ >/dev/null 2>&1 \
  || die "the lab-agent token cannot list kv/services/. Check the $POLICY policy."
echo "  the token lists and reads metadata, and is refused values"

if [ "$WRITE_VAULT" = "1" ] && [ -n "$CUR_ACCESSOR" ] && [ "$CUR_ACCESSOR" != "$NEW_ACCESSOR" ]; then
  # After the write, so a failed write never leaves lab-agent with no working token.
  vault token revoke -accessor "$CUR_ACCESSOR" >/dev/null 2>&1 \
    && echo "  revoked the previous token, accessor $CUR_ACCESSOR" \
    || echo "  the previous token, accessor $CUR_ACCESSOR, was already gone or could not be revoked. Check: vault token lookup -accessor $CUR_ACCESSOR"
fi
fi  # CHECK_ONLY

step "Check the deploy key reads petedio-vault"
# ⚠ A KEY GITHUB DOES NOT KNOW FAILS THE DEPLOY, NOT THIS SCRIPT. The play clones with it on
# 237, so it is checked here first, where the fix is one page away.
printf '%s\n' "$NEW_KEY" > "$TMP/deploy_check"
check_key(){
  GIT_SSH_COMMAND="ssh -i $TMP/deploy_check -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$TMP/known_hosts" \
    git ls-remote "$VAULT_REPO" HEAD >/dev/null 2>&1
}
if check_key; then
  echo "  GitHub accepts the key for petedio-vault"
elif [ -t 0 ]; then
  echo "  GitHub does not know this key yet. Add it as a READ-ONLY deploy key:"
  echo "    $DEPLOY_KEY_PAGE"
  echo "    Title: lab-agent on 237 (PET-670). Leave 'Allow write access' off."
  echo "    Key:   $NEW_PUB"
  read -rp "  Press Enter once it is added: " _
  check_key || die "GitHub still refuses the key. Add it as above, then run this script again; it keeps what it wrote."
  echo "  GitHub accepts the key for petedio-vault"
else
  die "GitHub does not know the deploy key yet. Add it read-only at $DEPLOY_KEY_PAGE with this public key, then run this again: $NEW_PUB"
fi
unset NEW_ASK NEW_VAULT NEW_KEY CUR_ASK CUR_VAULT CUR_KEY SNAPSHOT

step "Done"
cat <<'NOTE'
  Next:
    1. If kv/services/lab-agent-pve is not seeded yet, run, from ansible/:
         ansible-playbook playbooks/mint-pve-audit-token.yml -e pve_client=lab-agent
    2. Deploy: ./scripts/deploy-pete-bot.sh, or merge pete-bot's deploy.yml PR that reads
       both lab-agent paths. The play fails unless lab-agent's /health reports every check up.
NOTE
