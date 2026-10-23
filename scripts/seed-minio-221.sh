#!/usr/bin/env bash
# seed-minio-221.sh — seed the two Vault paths the PET-741 register check found absent:
#   kv/iac/minio-root            the .221 MinIO root credential (root_user, root_password)
#   kv/services/vault-snapshots  a svcacct scoped to the vault-snapshots bucket (access_key, secret_key)
#
# kv/iac/minio-root is the rebuild input for configure-minio.yml. Terraform's state backend
# does not use it: that is a tfstate-scoped svcacct at kv/iac/minio (reseed-minio-vault.sh).
# The vault-snapshot role reads kv/services/vault-snapshots (PET-109). The runbook minted
# it by hand; this script replaces that step.
#
# IDEMPOTENT. A path that already holds a working credential is left alone. Pass --refresh
# to overwrite kv/iac/minio-root, and to mint a new vault-snapshots svcacct and revoke the
# one Vault held.
#
#   Vault token: $VAULT_TOKEN, else macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM. No prompt (PET-519)
#   MinIO root:  $MINIO_ROOT_USER/$MINIO_ROOT_PASSWORD, else $MINIO_CREDS_FILE
#                (default ~/petedio/.secrets/minio-221.txt, lines ROOT_USER=… and ROOT_PASSWORD=…).
#                This script never prompts for it and never prints it.
#
# Usage:
#   ./scripts/seed-minio-221.sh            # seed what is absent
#   ./scripts/seed-minio-221.sh --refresh  # replace both
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
HOMELAB="$REPO_ROOT/environments/homelab"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"
MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://192.168.50.221:9000}"
MINIO_CREDS_FILE="${MINIO_CREDS_FILE:-$HOME/petedio/.secrets/minio-221.txt}"
ROOT_PATH="kv/iac/minio-root"
SNAP_PATH="kv/services/vault-snapshots"
BUCKET="vault-snapshots"

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }
for t in vault mc python3; do command -v "$t" >/dev/null || die "$t not in PATH."; done

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

step "MinIO root credential for $MINIO_ENDPOINT (used locally)"
MROOT_U="${MINIO_ROOT_USER:-}"; MROOT_P="${MINIO_ROOT_PASSWORD:-}"
if { [ -z "$MROOT_U" ] || [ -z "$MROOT_P" ]; } && [ -f "$MINIO_CREDS_FILE" ]; then
  # Match the exact key at the start of a line, split at the FIRST = or :, and strip only a
  # trailing CR and one pair of surrounding quotes. Every other byte of the value stays.
  cred(){ KEY="$1" FILE="$MINIO_CREDS_FILE" python3 -c '
import os, re
for line in open(os.environ["FILE"], encoding="utf-8").read().splitlines():
    m = re.match(r"^\s*(?:export\s+)?" + re.escape(os.environ["KEY"]) + r"\s*[=:]\s*(.*)$", line, re.I)
    if m:
        v = m.group(1)
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"\x27":
            v = v[1:-1]
        print(v, end="")
        break'; }
  [ -n "$MROOT_U" ] || MROOT_U="$(cred ROOT_USER)"
  [ -n "$MROOT_P" ] || MROOT_P="$(cred ROOT_PASSWORD)"
fi
[ -n "$MROOT_U" ] && [ -n "$MROOT_P" ] \
  || die "no MinIO root credential. Export MINIO_ROOT_USER and MINIO_ROOT_PASSWORD, or write them to $MINIO_CREDS_FILE."
MCCFG="$(mktemp -d)"; trap 'rm -rf "$MCCFG"' EXIT
m(){ mc --config-dir "$MCCFG" "$@"; }
# set_alias ALIAS USER PASS stores an alias. `mc alias set` reads both keys from stdin, and
# printf is a builtin, so neither key reaches argv. An MC_HOST_<alias> URL breaks on a raw
# `:`, `@` or `%` in a secret (seed-usaa-minio.sh).
set_alias(){
  printf '%s\n%s\n' "$2" "$3" | m alias set "$1" "$MINIO_ENDPOINT" --api s3v4 --path auto >/dev/null 2>&1
}
set_alias adm "$MROOT_U" "$MROOT_P" && m ls adm >/dev/null 2>&1 \
  || die "$MINIO_ENDPOINT rejected the root credential, or it is unreachable (is this machine on the .50 LAN?)."
echo "  the root credential authenticates (user length ${#MROOT_U})"


# snap PATH reads PATH into SNAPSHOT and sets VERSION: 0 when Vault says "No value found",
# else the current version. Any other failure (403, sealed, timeout) aborts, so an error never
# reads as absent. A soft-deleted current version aborts too.
snap(){
  local err
  if SNAPSHOT="$(vault kv get -format=json "$1" 2>/dev/null)"; then
    VERSION="$(SNAPSHOT="$SNAPSHOT" python3 -c '
import json, os
d = json.loads(os.environ["SNAPSHOT"])["data"]
print("deleted" if d.get("data") is None else d["metadata"]["version"])')" || die "could not parse the read of $1."
    [ "$VERSION" != "deleted" ] || die "the current version of $1 is deleted. Undelete or destroy it by hand, then run this again."
  elif err="$(vault kv metadata get "$1" 2>&1 >/dev/null)"; then
    die "$1 has metadata, but the token cannot read its data. Check the token's policy."
  else
    case "$err" in
      "No value found at "*) VERSION=0; SNAPSHOT='{}' ;;
      *) die "Vault failed the read of $1: $(printf '%s' "$err" | tr -s '\n\t' '  ' | cut -c1-200)" ;;
    esac
  fi
}
# field NAME prints a field of SNAPSHOT, or nothing.
field(){ SNAPSHOT="$SNAPSHOT" python3 -c '
import json, os, sys
try:
    d = json.loads(os.environ["SNAPSHOT"])["data"]["data"] or {}
except Exception:
    d = {}
print(d.get(sys.argv[1], ""))' "$1"; }
# write PATH JSON-ON-STDIN is check-and-set against VERSION: it creates only when the read found
# the path absent, patches (keeping other fields) when it exists, and fails if another writer
# changed the path since the read.
write(){
  if [ "$VERSION" = "0" ]; then vault kv put -cas=0 "$1" - >/dev/null
  else vault kv patch -cas="$VERSION" "$1" - >/dev/null; fi
}

step "$ROOT_PATH"
snap "$ROOT_PATH"
if [ "$REFRESH" = "0" ] && [ -n "$(field root_user)" ] && [ -n "$(field root_password)" ]; then
  echo "  already holds a root credential. Leaving it alone."
else
  MU="$MROOT_U" MP="$MROOT_P" python3 -c '
import json, os
print(json.dumps({"root_user": os.environ["MU"], "root_password": os.environ["MP"]}))' \
    | write "$ROOT_PATH" || die "the write to $ROOT_PATH failed, so Vault keeps what it held. Run this again."
  snap "$ROOT_PATH"
  [ "$(field root_user)" = "$MROOT_U" ] && [ "$(field root_password)" = "$MROOT_P" ] \
    || die "the read-back of $ROOT_PATH does not match."
  echo "  written, and the read-back matches"
fi

step "Bucket $BUCKET"
if m ls "adm/$BUCKET" >/dev/null 2>&1; then
  echo "  exists"
else
  m mb "adm/$BUCKET" >/dev/null || die "could not create the bucket $BUCKET."
  m version enable "adm/$BUCKET" >/dev/null || die "could not enable versioning on $BUCKET."
  echo "  created, with versioning"
fi

# in_scope ALIAS ACCESS_KEY proves a key against MinIO: it lists the bucket, sees no other
# bucket, and its policy read back from MinIO grants only these actions on this one bucket.
in_scope(){
  local alias="$1" ak="$2" listing info
  m ls "$alias/$BUCKET/" >/dev/null 2>&1 || { echo "  cannot list $BUCKET" >&2; return 1; }
  listing="$(m ls "$alias" 2>/dev/null)" || { echo "  cannot list its buckets, so its scope is unproven" >&2; return 1; }
  [ "$(printf '%s\n' "$listing" | grep -c .)" = "1" ] && printf '%s' "$listing" | grep -q "$BUCKET/\?\$" \
    || { echo "  does not see exactly the one bucket $BUCKET" >&2; return 1; }
  info="$(m admin user svcacct info --json adm "$ak" 2>/dev/null)" \
    || { echo "  MinIO has no service account with that key" >&2; return 1; }
  INFO="$info" BUCKET="$BUCKET" python3 -c '
import json, os, sys
pol = json.loads(os.environ["INFO"]).get("policy")
if isinstance(pol, str):
    pol = json.loads(pol) if pol else None
if not pol:
    sys.exit("  the key has no embedded policy, so it inherits the root policy")
b = os.environ["BUCKET"]
allowed = {"s3:ListBucket", "s3:GetBucketLocation", "s3:GetObject", "s3:PutObject",
           "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"}
scope = {f"arn:aws:s3:::{b}", f"arn:aws:s3:::{b}/*"}
for st in pol.get("Statement", []):
    acts = st.get("Action", []); acts = [acts] if isinstance(acts, str) else acts
    res = st.get("Resource", []); res = [res] if isinstance(res, str) else res
    if st.get("Effect") != "Allow" or not set(acts) <= allowed or not set(res) <= scope:
        sys.exit("  the policy grants more than the intended actions on this bucket")
' || return 1
}

step "$SNAP_PATH"
snap "$SNAP_PATH"
OLD_AK="$(field access_key)"; OLD_SK="$(field secret_key)"
if [ "$REFRESH" = "0" ] && [ -n "$OLD_AK" ] && [ -n "$OLD_SK" ] \
   && set_alias old "$OLD_AK" "$OLD_SK" && in_scope old "$OLD_AK" 2>/dev/null; then
  unset OLD_SK
  echo "  holds a credential that reaches $BUCKET with the intended scope. Leaving it alone."
else
  unset OLD_SK
  # The snapshot script uploads objects and the restore runbook lists and reads them.
  # It gets no delete and no access to any other bucket.
  POLICY="$MCCFG/vault-snapshots-policy.json"
  cat > "$POLICY" <<JSON
{ "Version":"2012-10-17","Statement":[
  {"Effect":"Allow","Action":["s3:ListBucket","s3:GetBucketLocation"],"Resource":["arn:aws:s3:::$BUCKET"]},
  {"Effect":"Allow","Action":["s3:GetObject","s3:PutObject","s3:AbortMultipartUpload","s3:ListMultipartUploadParts"],
   "Resource":["arn:aws:s3:::$BUCKET/*"]}
]}
JSON
  NAME="vault-snapshots-$(date -u +%Y%m%dT%H%M)"
  SVC_JSON="$(m admin user svcacct add --policy "$POLICY" --name "$NAME" \
    --description "PET-741 $BUCKET" --json adm "$MROOT_U")" \
    || die "MinIO refused the service account."
  NEW_AK="$(printf '%s' "$SVC_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("accessKey") or "")')"
  NEW_SK="$(printf '%s' "$SVC_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("secretKey") or "")')"
  unset SVC_JSON
  [ -n "$NEW_AK" ] && [ -n "$NEW_SK" ] || die "could not parse the minted service account. Check for $NAME with mc admin user svcacct ls."
  echo "  minted $NAME"
  set_alias chk "$NEW_AK" "$NEW_SK" \
    || die "mc could not store the alias for the new key. Remove $NAME with mc admin user svcacct rm."
  in_scope chk "$NEW_AK" \
    || die "the new key fails the checks above. Remove $NAME with mc admin user svcacct rm, then fix the policy."
  echo "  lists $BUCKET, sees no other bucket, and its policy holds only the intended actions"
  NK="$NEW_AK" NS="$NEW_SK" python3 -c '
import json, os
print(json.dumps({"access_key": os.environ["NK"], "secret_key": os.environ["NS"]}))' \
    | write "$SNAP_PATH" \
    || die "the write to $SNAP_PATH failed, so Vault keeps what it held. Remove $NAME with mc admin user svcacct rm, then run this again."
  snap "$SNAP_PATH"
  [ "$(field access_key)" = "$NEW_AK" ] && [ "$(field secret_key)" = "$NEW_SK" ] \
    || die "the read-back of $SNAP_PATH does not match."
  echo "  written, and the read-back matches"
  unset NEW_SK
  if [ -n "$OLD_AK" ] && [ "$OLD_AK" != "$NEW_AK" ]; then
    # Revoke the key Vault held. The snapshot job reads Vault on each run, so it picks up
    # the new key. MinIO keeps a replaced service account valid until it is removed.
    m admin user svcacct rm adm "$OLD_AK" >/dev/null 2>&1 || true
    if m admin user svcacct info --json adm "$OLD_AK" >/dev/null 2>&1; then
      die "the new key is in Vault, but the previous key ($OLD_AK) is still valid on MinIO. Run: mc admin user svcacct rm adm $OLD_AK"
    fi
    echo "  revoked the previous key ($OLD_AK), and MinIO no longer knows it"
  fi
fi
unset MROOT_P

step "Done"
cat <<'NOTE'
  Next: run the secrets-register workflow once with workflow_dispatch. To prove the snapshot
  path end to end, run `systemctl start vault-snapshot.service` on 223 and `mc ls` the bucket.
NOTE
