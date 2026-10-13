#!/usr/bin/env bash
# seed-plane-tom-pat.sh — mint Tom's Plane PAT in Plane's Django shell on LXC 235, and store
# it in kv/services/plane-tom (PET-610). Nobody sees the token: it travels from the api
# container's stdout into a variable here, and from there into Vault through stdin.
#
# WHY ITS OWN PATH. kv/services/plane holds Pedro's PAT, and the plane-ci role reads that
# path from a pull_request subject. Tom's token stays out of reach of every CI run.
#
# WHAT IT STORES: api_key (the PAT), user_email (whose it is) and token_id (Plane's row id,
# which --revoke-older keeps). A Plane PAT acts as its user, so the script refuses a user who
# is inactive, a bot, staff, a superuser, the workspace owner, an Admin of petedio, or not a
# member of petedio. Plane CE ignores a token's workspace field, so Tom's role is the scope.
#
# THE ORDER:
#   1. Pedro creates Tom's Authentik user and invites Tom to petedio as a Member. Tom signs
#      in to Plane once, which creates his Plane user.
#   2. this script --email <Tom's email>
#   3. The PR that adds :8791 merges, then ./scripts/apply-vault-config.sh, so the ansible
#      AppRole can read kv/services/plane-tom.
#   4. ./scripts/deploy-plane.sh, so the :8791 Caddy site holds the token.
# After --rotate, the old token stays valid. Run step 4, then this script --revoke-older.
#
#   Vault token: $VAULT_TOKEN, else the macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM.
#   This script never prompts for it, and it never prints the PAT.
#   Plane: ssh root@192.168.50.235 with ~/.ssh/id_ed25519_ansible, the key 235 trusts. When
#   235 refuses it, --via-pve03 runs the same command through `pct exec 235` on pve03.
#
# Usage:
#   ./scripts/seed-plane-tom-pat.sh --email tom@example.com   # mint one when absent, else keep it
#   ./scripts/seed-plane-tom-pat.sh --rotate                  # replace it
#   ./scripts/seed-plane-tom-pat.sh --revoke-older            # deactivate every older one
#   Add --via-pve03 to any of these.
set -euo pipefail
umask 077

MODE=seed EMAIL="" VIA=direct
while [ $# -gt 0 ]; do
  case "$1" in
    --email) [ $# -ge 2 ] || { echo "--email needs a value" >&2; exit 2; }; EMAIL="$2"; shift ;;
    --rotate) MODE=rotate ;;
    --revoke-older) MODE=revoke ;;
    --via-pve03) VIA=pve03 ;;
    -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PATH_KV="kv/services/plane-tom"
LABEL="pet-610-mcp-tom"
PLANE_URL="${PLANE_URL:-http://192.168.50.235:8080}"
WORKSPACE="petedio"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$REPO_ROOT/environments/homelab/vault-ca.crt}"

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }

for t in vault python3 ssh; do command -v "$t" >/dev/null || die "$t not in PATH."; done
if [ -n "$EMAIL" ]; then
  # The email goes into the program sent to Plane, so it must be an address and nothing else.
  printf '%s' "$EMAIL" | grep -Eq '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' \
    || die "--email is not an email address."
fi

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

# ---- Plane --------------------------------------------------------------------------------
# plane ACTION [KEY=VALUE...] runs PLANE_PY in the api container and prints its one result as
# JSON. The arguments travel in the program text on stdin, never in an ssh or docker argv,
# and the result, which can hold the new PAT, returns on stdout into a variable.
REMOTE='cd /opt/plane && docker compose --env-file plane.env exec -T api python manage.py shell'
plane_shell(){
  # PLANE_SHELL replaces the transport in tests: an executable that runs python from stdin.
  if [ -n "${PLANE_SHELL:-}" ]; then "$PLANE_SHELL"; return; fi
  case "$VIA" in
    direct) ssh -i ~/.ssh/id_ed25519_ansible -o BatchMode=yes -o ConnectTimeout=8 \
              root@192.168.50.235 "$REMOTE" ;;
    pve03) ssh -o BatchMode=yes -o ConnectTimeout=8 root@192.168.50.10 \
              "pct exec 235 -- sh -c '$REMOTE'" ;;
  esac
}
plane(){
  local args
  args="$(python3 -c '
import json, sys
print(json.dumps(dict(a.split("=", 1) for a in sys.argv[1:])))' "action=$1" "${@:2}" \
    "email=$EMAIL" "label=$LABEL" "workspace=$WORKSPACE")"
  { printf 'ARGS = %s\n' "$args"; printf '%s\n' "$PLANE_PY"; } | plane_shell \
    | sed -n 's/^SEED-RESULT //p' | tail -n 1
}
# get KEY, from the JSON in $RESULT, through the environment.
get(){ RESULT="$RESULT" python3 -c '
import json, os, sys
v = json.loads(os.environ["RESULT"] or "{}").get(sys.argv[1], "")
print(v if not isinstance(v, bool) else str(v).lower())' "$1"; }

read -r -d '' PLANE_PY <<'PYEOF' || true
import json
from plane.db.models import APIToken, User, Workspace, WorkspaceMember

def out(**kw):
    print("SEED-RESULT " + json.dumps(kw))

def tom():
    user = User.objects.filter(email__iexact=ARGS["email"]).first()
    if user is None:
        return None, "Plane has no user with that email. Invite them to petedio, and have them sign in once."
    ws = Workspace.objects.get(slug=ARGS["workspace"])
    if not user.is_active or user.is_bot:
        return None, "that Plane user is inactive or a bot."
    if user.is_superuser or user.is_staff:
        return None, "that Plane user is staff or a superuser, which is wider than Tom needs."
    if ws.owner_id == user.id:
        return None, "that Plane user owns the workspace. Is this Pedro's email?"
    m = WorkspaceMember.objects.filter(workspace=ws, member=user, is_active=True).first()
    if m is None:
        return None, "that Plane user is not an active member of " + ARGS["workspace"] + "."
    if m.role >= 20:
        return None, "that Plane user is an Admin of " + ARGS["workspace"] + ". Make them a Member, then run this again."
    return user, {5: "Guest", 15: "Member"}.get(m.role, str(m.role))

def mine(user):
    return APIToken.objects.filter(user=user, label=ARGS["label"], is_active=True)

user, info = tom()
if user is None:
    out(error=info)
elif ARGS["action"] == "mint":
    older = mine(user).count()
    t = APIToken.objects.create(
        user=user, user_type=0, label=ARGS["label"],
        description="Tom's MCP connector at mcp-tom.pdlab.dev. Stored at kv/services/plane-tom "
                    "by iac/scripts/seed-plane-tom-pat.sh (PET-610).",
    )
    out(token=t.token, token_id=str(t.id), role=info, older=older)
elif ARGS["action"] == "revoke-one":
    n = mine(user).filter(id=ARGS["token_id"]).update(is_active=False)
    out(revoked=n)
elif ARGS["action"] == "revoke-older":
    keep = mine(user).filter(id=ARGS["keep"])
    if not keep.exists():
        out(error="the stored token_id is not an active token of that user, so nothing was revoked.")
    else:
        out(revoked=mine(user).exclude(id=ARGS["keep"]).update(is_active=False), role=info)
else:
    out(error="unknown action " + ARGS["action"])
PYEOF

# api_check reads $NEW from the environment and asks Plane who it belongs to. It prints the
# user's email and whether the workspace's projects answer, never the token.
api_check(){ TOKEN="$NEW" python3 -c '
import json, os, sys, urllib.request
base, ws = sys.argv[1], sys.argv[2]
def call(path):
    req = urllib.request.Request(base + path, headers={"X-API-Key": os.environ["TOKEN"]})
    with urllib.request.urlopen(req, timeout=15) as r:
        return r.status, json.load(r)
_, me = call("/api/v1/users/me/")
status, _ = call("/api/v1/workspaces/%s/projects/" % ws)
print(me.get("email", ""), status)' "$PLANE_URL" "$WORKSPACE" 2>/dev/null || true; }

# revoke_minted TOKEN_ID deactivates a token this run minted and could not store.
revoke_minted(){
  RESULT="$(plane revoke-one "token_id=$1" || true)"
  if [ "$(get revoked)" = "1" ]; then
    echo "  deactivated the token this run minted, so no orphan stays valid" >&2
  else
    echo "  WARNING: could not deactivate token $1 in Plane. Deactivate it by hand." >&2
  fi
}

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
CURRENT="$(field api_key)"
STORED_EMAIL="$(field user_email)"
STORED_ID="$(field token_id)"

# A stored token belongs to one person. Retargeting it to another email is a new decision,
# not a rotation, so it takes a hand edit.
if [ -n "$STORED_EMAIL" ]; then
  if [ -z "$EMAIL" ]; then
    EMAIL="$STORED_EMAIL"
  elif [ "$(printf '%s' "$EMAIL" | tr '[:upper:]' '[:lower:]')" != \
         "$(printf '%s' "$STORED_EMAIL" | tr '[:upper:]' '[:lower:]')" ]; then
    die "$PATH_KV holds a token for another email. Nothing was changed."
  fi
fi
[ -n "$EMAIL" ] || die "the path is empty, so the first seed needs --email <Tom's email>."

if [ "$MODE" = "revoke" ]; then
  step "Deactivate Tom's older tokens"
  if [ -z "$CURRENT" ] || [ -z "$STORED_ID" ]; then
    die "$PATH_KV holds no api_key and token_id to keep."
  fi
  NEW="$CURRENT"
  read -r WHO STATUS <<<"$(api_check)"
  unset NEW
  if [ "$WHO" != "$EMAIL" ] || [ "$STATUS" != "200" ]; then
    die "the stored token does not answer as $EMAIL, so nothing was revoked."
  fi
  RESULT="$(plane revoke-older "keep=$STORED_ID")" || die "the Plane call failed."
  [ -n "$RESULT" ] || die "Plane returned no result. Run with --via-pve03 if 235 refused SSH."
  [ -z "$(get error)" ] || die "$(get error)"
  echo "  kept token_id $STORED_ID, deactivated $(get revoked) older"
  unset CURRENT SNAPSHOT RESULT
  exit 0
fi

if [ -n "$CURRENT" ] && [ "$MODE" = "seed" ]; then
  echo "  api_key: present, ${#CURRENT} characters. Kept (--rotate replaces it)."
  unset CURRENT SNAPSHOT
  exit 0
fi

step "Mint Tom's PAT in Plane"
RESULT="$(plane mint)" || die "the Plane call failed."
[ -n "$RESULT" ] || die "Plane returned no result. Run with --via-pve03 if 235 refused SSH."
[ -z "$(get error)" ] || die "$(get error)"
NEW="$(get token)"
NEW_ID="$(get token_id)"
OLDER="$(get older)"
echo "  minted for $EMAIL, workspace role $(get role), ${#NEW} characters"
unset RESULT
if [ -z "$NEW" ] || [ -z "$NEW_ID" ]; then
  die "the result held no token. Check Plane by hand for an orphan labelled $LABEL."
fi
[ "$NEW" != "$CURRENT" ] || { revoke_minted "$NEW_ID"; die "the minted token repeats the stored one."; }

step "Prove it acts as Tom"
read -r WHO STATUS <<<"$(api_check)"
if [ "$WHO" != "$EMAIL" ] || [ "$STATUS" != "200" ]; then
  revoke_minted "$NEW_ID"
  die "the new token did not answer as $EMAIL with the workspace's projects (got '${WHO:-nothing}' ${STATUS:-})."
fi
echo "  /users/me/ answers $WHO, and /workspaces/$WORKSPACE/projects/ answers 200"

step "Write $PATH_KV"
# The JSON reaches vault on stdin, so the token never reaches argv. -cas=0 creates only, and
# -cas=VERSION fails when another writer changed the path since the read.
payload(){ NEW="$NEW" NEW_ID="$NEW_ID" EMAIL="$EMAIL" python3 -c '
import json, os
print(json.dumps({"api_key": os.environ["NEW"], "token_id": os.environ["NEW_ID"],
                  "user_email": os.environ["EMAIL"]}))'; }
case "$VERSION" in
  0) payload | vault kv put -cas=0 "$PATH_KV" - >/dev/null \
       || { revoke_minted "$NEW_ID"; die "vault kv put failed for $PATH_KV. If another writer created it, run this again."; } ;;
  [1-9]*) payload | vault kv patch -cas="$VERSION" "$PATH_KV" - >/dev/null \
       || { revoke_minted "$NEW_ID"; die "vault kv patch failed for $PATH_KV. If another writer changed it, run this again."; } ;;
  *) revoke_minted "$NEW_ID"; die "unrecognized version for $PATH_KV: $VERSION" ;;
esac

step "Verify, by reading it back"
SNAPSHOT="$(vault kv get -format=json "$PATH_KV")"
[ "$(field api_key)" = "$NEW" ] || die "the read-back does not match the write."
[ "$(field token_id)" = "$NEW_ID" ] || die "the read-back token_id does not match the write."
AFTER="$(names)"
for f in $BEFORE; do
  case " $AFTER " in *" $f "*) ;; *) die "the write dropped the field $f." ;; esac
done
echo "  api_key: ${#NEW} characters, matches the write"
echo "  token_id: $NEW_ID"
echo "  fields: $AFTER, at version $(version)"
unset NEW CURRENT SNAPSHOT

step "Done"
if [ "${OLDER:-0}" != "0" ]; then
  echo "  $OLDER older token(s) labelled $LABEL stay valid until --revoke-older."
fi
cat <<NOTE
  Next, in this order:
    1. Merge the PR that adds :8791, then run ./scripts/apply-vault-config.sh, so the ansible
       AppRole can read $PATH_KV.
    2. ./scripts/deploy-plane.sh, so the :8791 Caddy site holds the token.
    3. After a rotation only: ./scripts/seed-plane-tom-pat.sh --revoke-older
NOTE
