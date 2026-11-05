#!/usr/bin/env bash
# export-remove-usaa-statements.sh — export the usaa-statements bucket to a local directory,
# prove the copy by content, then (only with --remove) delete the bucket (PET-590).
#
# THE BUCKET IS THE ONLY COPY of six years of bank statements and usaa.db. Pedro chose
# "export, then remove" on 2026-11-05. The script never removes anything until every object
# in the export matches the bucket byte for byte.
#
# STEPS
#   1. Export:  mc mirror (no --remove) into DEST/objects, never into a non-empty DEST.
#   2. Verify:  sha256 of every local file against sha256 of `mc cat` for the same key, and
#               the object count against the bucket listing. Writes DEST/SHA256SUMS.
#               If sqlite3 is installed, DEST/objects/data/usaa.db must pass an integrity check.
#   3. Remove (--remove only, typed confirmation): delete every object version, then the
#               bucket, then the scoped MinIO key recorded at kv/services/usaa-minio, then
#               that Vault path. Each step is read back; a step that cannot be proven fails.
#
# Without --remove the script stops after step 2 and the bucket is untouched. Re-run with
# --remove --dest DEST to remove: it re-verifies the export first, so a changed or damaged
# export blocks the removal.
#
# DEST holds financial data. Choose a private, backed-up location, and never a git checkout.
# Credentials: Vault token from $VAULT_TOKEN, else the macOS Keychain item
# $VAULT_TOKEN_KEYCHAIN_ITEM. MinIO root credentials come from kv/iac/minio-data-root and reach
# `mc` on stdin, never argv. The script prints paths and counts, never a value.
#
# Usage:
#   ./scripts/export-remove-usaa-statements.sh --dest ~/usaa-export          # export + verify
#   ./scripts/export-remove-usaa-statements.sh --dest ~/usaa-export --remove # then delete
set -euo pipefail
umask 077

DEST=""; REMOVE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dest) [ $# -ge 2 ] || { echo "--dest needs a directory" >&2; exit 2; }; DEST="$2"; shift 2 ;;
    --remove) REMOVE=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$DEST" ] || { echo "FAIL: --dest DIR is required" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$REPO_ROOT/environments/homelab/vault-ca.crt}"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"
MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://192.168.50.245:9000}"
BUCKET="usaa-statements"
ROOT_PATH="kv/iac/minio-data-root"
SVC_PATH="kv/services/usaa-minio"

die(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
step(){ printf '\n== %s ==\n' "$*"; }
for t in mc vault python3 sha256sum; do
  command -v "$t" >/dev/null || { [ "$t" = sha256sum ] && command -v shasum >/dev/null && continue; die "$t not in PATH"; }
done
sha(){ if command -v sha256sum >/dev/null; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi; }

case "$(cd "$(dirname "$DEST")" 2>/dev/null && pwd)/$(basename "$DEST")" in
  "$REPO_ROOT"|"$REPO_ROOT"/*) die "DEST is inside this git checkout; financial data must not land in a repo" ;;
esac

if [ -z "${VAULT_TOKEN:-}" ] && command -v security >/dev/null; then
  VAULT_TOKEN="$(security find-generic-password -s "$VAULT_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null || true)"
  export VAULT_TOKEN
fi
[ -n "${VAULT_TOKEN:-}" ] || die "no Vault token (set VAULT_TOKEN or the Keychain item)"

MCCFG="$(mktemp -d)"; trap 'rm -rf "$MCCFG"' EXIT
m(){ mc --config-dir "$MCCFG" "$@"; }

step "MinIO root alias"
RU="$(vault kv get -field=root_user "$ROOT_PATH")" || die "cannot read root_user from $ROOT_PATH"
RP="$(vault kv get -field=root_password "$ROOT_PATH")" || die "cannot read root_password from $ROOT_PATH"
[ -n "$RU" ] && [ -n "$RP" ] || die "root credential at $ROOT_PATH is empty"
printf '%s\n%s\n' "$RU" "$RP" | m alias set adm "$MINIO_ENDPOINT" --api s3v4 --path auto >/dev/null 2>&1 \
  || die "cannot set the MinIO alias for $MINIO_ENDPOINT"
unset RU RP
m ls "adm/$BUCKET/" >/dev/null 2>&1 || die "cannot list adm/$BUCKET (bucket missing or MinIO unreachable)"
echo "ok: $BUCKET reachable at $MINIO_ENDPOINT"

# Latest-version keys, one per line, from the bucket listing.
list_keys(){ m ls --recursive --json "adm/$BUCKET/" | python3 -c '
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    d = json.loads(line)
    if d.get("status") != "success": sys.exit("listing error: %s" % line)
    if d.get("type") == "file": print(d["key"])
'; }

OBJ="$DEST/objects"
if [ -e "$DEST" ] && [ -n "$(ls -A "$DEST" 2>/dev/null)" ] && [ ! -d "$OBJ" ]; then
  die "$DEST exists and is not an export from this script; choose an empty directory"
fi

step "Export"
mkdir -p "$OBJ"
m mirror --overwrite "adm/$BUCKET" "$OBJ" >/dev/null || die "mc mirror failed"

step "Verify by content"
KEYS="$(list_keys)" || die "cannot list bucket objects"
n_bucket="$(printf '%s\n' "$KEYS" | grep -c . || true)"
[ "$n_bucket" -ge 1 ] || die "bucket lists 0 objects; refusing to call an empty export verified"
echo "bucket lists $n_bucket objects"
: > "$DEST/SHA256SUMS"
bad=0; checked=0
while IFS= read -r k; do
  [ -n "$k" ] || continue
  f="$OBJ/$k"
  [ -f "$f" ] || { echo "MISSING locally: $k" >&2; bad=$((bad+1)); continue; }
  want="$(m cat "adm/$BUCKET/$k" | sha)" || { echo "cannot read from bucket: $k" >&2; bad=$((bad+1)); continue; }
  have="$(sha < "$f")"
  if [ "$want" = "$have" ]; then
    printf '%s  %s\n' "$have" "$k" >> "$DEST/SHA256SUMS"; checked=$((checked+1))
  else
    echo "MISMATCH: $k" >&2; bad=$((bad+1))
  fi
done <<< "$KEYS"
n_local="$(find "$OBJ" -type f | grep -c . || true)"
[ "$bad" = 0 ] || die "$bad of $n_bucket objects failed verification; nothing was removed"
[ "$checked" = "$n_bucket" ] || die "verified $checked of $n_bucket objects"
[ "$n_local" = "$n_bucket" ] || die "export holds $n_local files, bucket lists $n_bucket; extra files in $OBJ"
echo "verified $checked of $n_bucket objects by sha256 (manifest: $DEST/SHA256SUMS)"
if command -v sqlite3 >/dev/null && [ -f "$OBJ/data/usaa.db" ]; then
  [ "$(sqlite3 "$OBJ/data/usaa.db" 'PRAGMA integrity_check;')" = ok ] || die "data/usaa.db fails the SQLite integrity check"
  echo "ok: data/usaa.db passes the SQLite integrity check"
else
  echo "note: sqlite3 integrity check skipped (sqlite3 missing or no data/usaa.db)"
fi

if [ "$REMOVE" != 1 ]; then
  echo
  echo "Export verified. The bucket is untouched. Back up $DEST, then re-run with --remove."
  exit 0
fi

step "Remove"
printf 'This deletes bucket %s and every version of its %s objects. The copy is %s.\nType the bucket name to continue: ' "$BUCKET" "$n_bucket" "$DEST"
read -r answer
[ "$answer" = "$BUCKET" ] || die "confirmation did not match; nothing was removed"

# Every version, then the bucket. `rb --force` removes the objects and versions it holds.
m rb --force --dangerous "adm/$BUCKET" >/dev/null || die "mc rb failed"
if m ls "adm/$BUCKET/" >/dev/null 2>&1; then die "bucket still answers after rb"; fi
if m ls adm 2>/dev/null | grep -q "$BUCKET/"; then die "bucket still listed after rb"; fi
echo "gone: bucket $BUCKET (read back: not listed)"

# Scoped key recorded in Vault. Absent Vault path is fine; any other read error is not.
out="$(vault kv get -format=json "$SVC_PATH" 2>&1)" && rc=0 || rc=$?
if [ "$rc" = 0 ]; then
  AK="$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["data"]["access_key"])')" \
    || die "cannot parse access_key at $SVC_PATH"
  if m admin user svcacct info adm "$AK" >/dev/null 2>&1; then
    m admin user svcacct rm adm "$AK" >/dev/null || die "cannot remove the scoped MinIO key"
    if m admin user svcacct info adm "$AK" >/dev/null 2>&1; then die "scoped key still exists"; fi
    echo "gone: scoped MinIO key recorded at $SVC_PATH"
  else
    echo "absent: scoped MinIO key (MinIO has no such key)"
  fi
  vault kv metadata delete "$SVC_PATH" >/dev/null || die "cannot delete $SVC_PATH"
  after="$(vault kv metadata get -format=json "$SVC_PATH" 2>&1)" && die "$SVC_PATH still present"
  printf '%s' "$after" | grep -q "No value found" || die "cannot confirm $SVC_PATH is gone: $after"
  echo "gone: $SVC_PATH"
elif printf '%s' "$out" | grep -q "No value found"; then
  echo "absent: $SVC_PATH"
else
  die "cannot read $SVC_PATH: $out"
fi
echo
echo "Done. Next: merge the follow-up that removes the bucket from minio_data.yml (PET-590)."
