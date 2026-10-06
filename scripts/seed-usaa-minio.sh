#!/usr/bin/env bash
# seed-usaa-minio.sh — mint a READ-ONLY MinIO service account scoped to the
# `usaa-statements` bucket on minio-data-245, and store it at kv/services/usaa-minio
# (PET-590).
#
# WHY ITS OWN CREDENTIAL. Reading the bucket otherwise takes kv/iac/minio-data-root, which
# is admin on the whole host. This key lists and reads one bucket and nothing else. It
# cannot write, delete or change a version, so no consumer can damage the only copy of six
# years of statements. The script reads the key's policy back from MinIO and refuses a key
# whose policy grants any action beyond the three read actions below.
#
# WHO READS IT. scripts/deploy-usaa.sh and configure-usaa.yml, through the ansible policy's
# kv/data/services/* grant, and the Mac when it copies data/usaa.db for the ledger import.
# claude-ops on 247 does not (Pedro's decision, 2026-10-06).
#
# A ROTATION. --rotate mints a second key and writes it to Vault. The old key stays valid
# until you remove it, so the running app keeps reading until its next deploy. The script
# counts the older usaa keys; remove each one once scripts/deploy-usaa.sh has run.
#
#   Vault token: $VAULT_TOKEN, else the macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM.
#   MinIO admin: kv/iac/minio-data-root, read here and never written back.
#   This script never prompts for a credential, and it never prints one. MinIO
#   credentials reach `mc` on stdin, into a temporary config dir, never as an argv element.
#
# Requires the LAN or the tailnet to reach 192.168.50.245, and configure-minio-data.yml
# to have created the bucket.
#
# Usage:
#   ./scripts/seed-usaa-minio.sh            # mint one when absent or out of scope, else keep it
#   ./scripts/seed-usaa-minio.sh --rotate   # mint a replacement
set -euo pipefail
umask 077

ROTATE=0
for arg in "$@"; do
  case "$arg" in
    --rotate) ROTATE=1 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"
MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://192.168.50.245:9000}"
ROOT_PATH="kv/iac/minio-data-root"
DEST_PATH="kv/services/usaa-minio"
BUCKET="usaa-statements"
# The object a read proof stats. A stat needs s3:GetObject and reads no content.
PROBE_OBJECT="${USAA_PROBE_OBJECT:-data/usaa.db}"
NAME_PREFIX="usaa-ro-"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$REPO_ROOT/environments/homelab/vault-ca.crt}"

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }

for t in mc vault python3; do command -v "$t" >/dev/null || die "$t not in PATH."; done

MCCFG="$(mktemp -d)"
trap 'rm -rf "$MCCFG"' EXIT
m(){ mc --config-dir "$MCCFG" "$@"; }

# set_alias ALIAS USER PASS writes an alias into the temporary config dir. `mc alias set`
# reads both keys from stdin, and printf is a builtin, so neither key reaches argv. An
# MC_HOST_<alias> URL does not work here: mc neither decodes %-escapes in it nor survives a
# raw `:` or `@` in a secret.
set_alias(){
  printf '%s\n%s\n' "$2" "$3" \
    | m alias set "$1" "$MINIO_ENDPOINT" --api s3v4 --path auto >/dev/null 2>&1
}

# in_scope ALIAS ACCESS_KEY proves a key against MinIO itself: it reads the bucket, sees no
# other bucket, and its policy, read back from MinIO, grants only the three read actions on
# this one bucket. Returns non-zero, with the reason on stderr, on any miss.
in_scope(){
  local alias="$1" ak="$2" visible info
  m ls "$alias/$BUCKET/" >/dev/null 2>&1 \
    || { echo "  cannot list $BUCKET" >&2; return 1; }
  m stat "$alias/$BUCKET/$PROBE_OBJECT" >/dev/null 2>&1 \
    || { echo "  cannot read $BUCKET/$PROBE_OBJECT" >&2; return 1; }
  visible="$(m ls "$alias" 2>/dev/null | grep -c . || true)"
  [ "$visible" -le 1 ] \
    || { echo "  sees $visible buckets, expected 1" >&2; return 1; }
  info="$(m admin user svcacct info --json adm "$ak" 2>/dev/null)" \
    || { echo "  MinIO has no service account with that key" >&2; return 1; }
  INFO="$info" BUCKET="$BUCKET" python3 -c '
import json, os, sys
info = json.loads(os.environ["INFO"])
pol = info.get("policy")
if isinstance(pol, str):
    pol = json.loads(pol) if pol else None
if not pol:
    sys.exit("  the key has no embedded policy, so it inherits the root policy")
b = os.environ["BUCKET"]
allowed = {"s3:ListBucket", "s3:GetBucketLocation", "s3:GetObject"}
scope = {f"arn:aws:s3:::{b}", f"arn:aws:s3:::{b}/*"}
stmts = pol.get("Statement", [])
if not stmts:
    sys.exit("  the embedded policy has no statements")
for s in stmts:
    acts = s.get("Action", [])
    res = s.get("Resource", [])
    acts = [acts] if isinstance(acts, str) else acts
    res = [res] if isinstance(res, str) else res
    eff = s.get("Effect")
    if eff != "Allow":
        sys.exit(f"  unexpected effect {eff!r}")
    if not set(acts) <= allowed:
        sys.exit(f"  the policy grants {sorted(set(acts) - allowed)}")
    if not set(res) <= scope:
        sys.exit(f"  the policy reaches {sorted(set(res) - scope)}")
'
}

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

step "MinIO admin at $MINIO_ENDPOINT, from $ROOT_PATH"
MROOT_U="$(vault kv get -field=root_user "$ROOT_PATH" 2>/dev/null || true)"
MROOT_P="$(vault kv get -field=root_password "$ROOT_PATH" 2>/dev/null || true)"
[ -n "$MROOT_U" ] && [ -n "$MROOT_P" ] \
  || die "$ROOT_PATH is not seeded. Run scripts/seed-minio-data-root.sh first."
set_alias adm "$MROOT_U" "$MROOT_P" || die "mc could not store the admin alias."
unset MROOT_P
m admin info adm >/dev/null 2>&1 \
  || die "MinIO refused the admin credential, or 245 is unreachable. Is the LAN or the tailnet up?"
# The bucket is the role's job (group_vars/minio_data.yml), with its versioning and quota.
m ls "adm/$BUCKET" >/dev/null 2>&1 \
  || die "bucket $BUCKET does not exist. Run configure-minio-data.yml first."
# Check the read proof's object before minting, so a wrong path cannot strand a new key.
m stat "adm/$BUCKET/$PROBE_OBJECT" >/dev/null 2>&1 \
  || die "$BUCKET has no $PROBE_OBJECT. Set USAA_PROBE_OBJECT to an object it holds."
echo "  authenticated, and $BUCKET holds $PROBE_OBJECT"

step "Check $DEST_PATH"
OLD_AK="$(vault kv get -field=access_key "$DEST_PATH" 2>/dev/null || true)"
OLD_SK="$(vault kv get -field=secret_key "$DEST_PATH" 2>/dev/null || true)"
if [ -n "$OLD_AK" ] && [ -n "$OLD_SK" ]; then
  set_alias old "$OLD_AK" "$OLD_SK" || die "mc could not store the alias for the stored key."
  unset OLD_SK
  if in_scope old "$OLD_AK"; then
    case "$ROTATE" in
      0) echo "  the stored key works and is read-only on $BUCKET. Kept (--rotate replaces it)."
         exit 0 ;;
      1) echo "  the stored key works. Minting its replacement, as --rotate asks." ;;
      *) die "unrecognized value for ROTATE: $ROTATE" ;;
    esac
  else
    echo "  the stored key fails the checks above. Minting a replacement."
  fi
  m alias rm old >/dev/null 2>&1 || true
else
  unset OLD_SK
  echo "  absent. Minting one."
fi

step "Mint a service account that reads $BUCKET only"
POLICY="$MCCFG/usaa-read.json"
# List and locate the bucket, and get objects. Deliberately absent: every Put, Delete and
# version action, and every resource outside this one bucket.
cat > "$POLICY" <<JSON
{ "Version":"2012-10-17","Statement":[
  {"Effect":"Allow",
   "Action":["s3:ListBucket","s3:GetBucketLocation"],
   "Resource":["arn:aws:s3:::$BUCKET"]},
  {"Effect":"Allow",
   "Action":["s3:GetObject"],
   "Resource":["arn:aws:s3:::$BUCKET/*"]}
]}
JSON
NAME="${NAME_PREFIX}$(date -u +%Y%m%dT%H%M)"
SVC_JSON="$(m admin user svcacct add --policy "$POLICY" --name "$NAME" \
  --description "PET-590 read-only $BUCKET" --json adm "$MROOT_U")" \
  || die "MinIO refused the service account."
NEW_AK="$(printf '%s' "$SVC_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("accessKey") or "")')"
NEW_SK="$(printf '%s' "$SVC_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("secretKey") or "")')"
unset SVC_JSON
[ -n "$NEW_AK" ] && [ -n "$NEW_SK" ] || die "could not parse the minted service account."
echo "  minted $NAME"

step "Verify the new key against MinIO"
set_alias chk "$NEW_AK" "$NEW_SK" \
  || die "mc could not store the alias for the new key. Remove $NAME with mc admin user svcacct rm."
in_scope chk "$NEW_AK" \
  || die "the new key fails the checks above. Remove $NAME with mc admin user svcacct rm, then fix the policy."
echo "  reads $BUCKET, sees no other bucket, and its policy holds only the three read actions"

step "Write $DEST_PATH"
# JSON on stdin, so neither key reaches argv. `put` fits: the path holds this key alone.
U_AK="$NEW_AK" U_SK="$NEW_SK" U_EP="$MINIO_ENDPOINT" U_BK="$BUCKET" python3 -c '
import json, os
print(json.dumps({"access_key": os.environ["U_AK"], "secret_key": os.environ["U_SK"],
                  "endpoint": os.environ["U_EP"], "bucket": os.environ["U_BK"]}))
' | vault kv put "$DEST_PATH" - >/dev/null || die "vault kv put failed for $DEST_PATH."

step "Verify, by reading it back"
SNAPSHOT="$(vault kv get -format=json "$DEST_PATH")"
SNAPSHOT="$SNAPSHOT" U_AK="$NEW_AK" U_SK="$NEW_SK" U_EP="$MINIO_ENDPOINT" U_BK="$BUCKET" python3 -c '
import json, os, sys
d = json.loads(os.environ["SNAPSHOT"])["data"]["data"]
want = {"access_key": os.environ["U_AK"], "secret_key": os.environ["U_SK"],
        "endpoint": os.environ["U_EP"], "bucket": os.environ["U_BK"]}
bad = [k for k in want if d.get(k) != want[k]]
if bad:
    sys.exit("the read-back differs in: " + ", ".join(bad))
' || die "the read-back of $DEST_PATH does not match the write."
unset SNAPSHOT NEW_SK
echo "  access_key, secret_key, endpoint and bucket match the write"

step "Older usaa keys"
# Every rotation leaves the previous key valid until you remove it. This counts the older
# keys by name, so they cannot pile up unseen, and prints no key.
m admin user svcacct ls --json adm "$MROOT_U" 2>/dev/null \
  | CUR="$NEW_AK" PREFIX="$NAME_PREFIX" python3 -c '
import json, os, sys
rows = [json.loads(l) for l in sys.stdin if l.strip()]
older = [r for r in rows
         if (r.get("name") or "").startswith(os.environ["PREFIX"])
         and r.get("accessKey") != os.environ["CUR"]]
print(f"  read {len(rows)} service accounts; {len(older)} older usaa key(s) still valid")
' || echo "  could not list the service accounts. Check by hand with mc admin user svcacct ls."
unset NEW_AK MROOT_U

step "Done"
cat <<TXT
  Bucket  : $BUCKET, read only
  Endpoint: $MINIO_ENDPOINT (LAN and tailnet only, by design)
  Vault   : $DEST_PATH
TXT
case "$ROTATE" in
  0) ;;
  1) echo "  Next: ./scripts/deploy-usaa.sh, then remove each older usaa key." ;;
  *) die "unrecognized value for ROTATE: $ROTATE" ;;
esac
