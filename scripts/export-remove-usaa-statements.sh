#!/usr/bin/env bash
# export-remove-usaa-statements.sh — export the usaa-statements bucket to a local directory,
# prove the copy by content, then (only with --remove) delete the bucket (PET-590).
#
# THE BUCKET IS THE ONLY COPY of six years of bank statements and usaa.db. Pedro chose
# "export, then remove" on 2026-11-05. The script never removes anything until every object
# in the export matches the bucket byte for byte.
#
# STEPS
#   1. Export:  mc mirror (no --remove) of the current objects into DEST/objects, plus every
#               noncurrent version into DEST/versions/<versionId>/<key>, plus the version
#               inventory (delete markers included) in DEST/VERSIONS.tsv.
#   2. Verify:  sha256 of every local file against sha256 of the bucket's bytes, and the file
#               count against the bucket's version listing. Writes DEST/SHA256SUMS.
#               If sqlite3 is installed, DEST/objects/data/usaa.db must pass an integrity check.
#   3. Remove (--remove only, typed confirmation): delete every object version, then the
#               bucket, then the scoped MinIO key recorded at kv/services/usaa-minio, then
#               that Vault path. Each step is read back; a step that cannot be proven fails.
#
# Without --remove the script stops after step 2 and the bucket is untouched. Re-run with
# --remove --dest DEST to remove. That run changes nothing in DEST: it checks the saved export
# against the saved manifest, the saved inventory and the live bucket, so a damaged export or a
# changed bucket blocks the removal. After a bucket change, run a fresh export and backup first.
#
# DEST holds financial data. Choose a private, backed-up location. The script refuses any
# destination under a git checkout, symlinks resolved.
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

# Refuse any destination under a git checkout (this repo, the workspace, any other), and a
# symlink into one. realpath resolves symlinks; the walk looks for a .git entry at every
# ancestor. A destination that cannot be resolved fails closed.
REAL_DEST="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$DEST")" \
  || die "cannot resolve --dest $DEST"
[ -n "$REAL_DEST" ] || die "cannot resolve --dest $DEST"
d="$REAL_DEST"
while :; do
  [ ! -e "$d/.git" ] || die "DEST resolves to $REAL_DEST, inside the git checkout at $d; financial data must not land in a repo"
  [ "$d" != "/" ] || break
  d="$(dirname "$d")"
done
DEST="$REAL_DEST"

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

OBJ="$DEST/objects"; VER="$DEST/versions"
MANIFEST="$DEST/SHA256SUMS"; INVENTORY="$DEST/VERSIONS.tsv"
if [ -e "$DEST" ] && [ -n "$(ls -A "$DEST" 2>/dev/null)" ] && [ ! -d "$OBJ" ]; then
  die "$DEST exists and is not an export from this script; choose an empty directory"
fi

# Version inventory: key<TAB>versionId<TAB>isDeleteMarker<TAB>isLatest, sorted. Includes every
# historical version and delete marker, which `mc rb --force` also destroys.
list_versions(){ m ls --versions --recursive --json "adm/$BUCKET/" | python3 -c '
import json, sys
rows = []
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    d = json.loads(line)
    if d.get("status") != "success": sys.exit("listing error: %s" % line)
    if d.get("type") == "file":
        rows.append("%s\t%s\t%s\t%s" % (d["key"], d.get("versionId") or "null",
                    str(bool(d.get("isDeleteMarker"))).lower(), str(bool(d.get("isLatest"))).lower()))
print("\n".join(sorted(rows)))
'; }

INV="$(list_versions)" || die "cannot list bucket versions"
n_ver="$(printf '%s\n' "$INV" | grep -c . || true)"
[ "$n_ver" -ge 1 ] || die "bucket lists 0 versions; refusing to call an empty export verified"
n_dm="$(printf '%s\n' "$INV" | awk -F'\t' '$3=="true"' | grep -c . || true)"
echo "bucket lists $n_ver versions ($n_dm delete markers)"

if [ "$REMOVE" != 1 ]; then
  step "Export"
  mkdir -p "$OBJ" "$VER"
  m mirror --overwrite "adm/$BUCKET" "$OBJ" >/dev/null || die "mc mirror failed"
  # Every non-delete-marker version, including noncurrent ones, under versions/<id>/<key>.
  while IFS=$'\t' read -r k vid dm _latest; do
    [ -n "$k" ] && [ "$dm" = false ] || continue
    mkdir -p "$VER/$vid/$(dirname "$k")"
    m cat --version-id "$vid" "adm/$BUCKET/$k" > "$VER/$vid/$k" || die "cannot export version $vid of $k"
  done <<< "$INV"
  printf '%s\n' "$INV" > "$INVENTORY"
else
  step "Verify the saved export (read-only)"
  [ -f "$MANIFEST" ] && [ -f "$INVENTORY" ] || die "no saved export in $DEST (SHA256SUMS or VERSIONS.tsv missing); run without --remove first"
  [ "$(cat "$INVENTORY")" = "$INV" ] || die "the bucket's version inventory differs from the saved export; the bucket changed. Run a fresh export and backup cycle (without --remove) first"
fi

step "Verify by content"
KEYS="$(list_keys)" || die "cannot list bucket objects"
n_bucket="$(printf '%s\n' "$KEYS" | grep -c . || true)"
[ "$n_bucket" -ge 1 ] || die "bucket lists 0 current objects"
NEWMAN="$(mktemp "$MCCFG/manifest.XXXXXX")"
bad=0; checked=0
# check REL BUCKET_CMD...: hash the bucket side and the local file; in remove mode the saved
# manifest must agree as well.
check(){
  local rel="$1"; shift
  local f="$DEST/$rel" want have saved
  [ -f "$f" ] || { echo "MISSING locally: $rel" >&2; bad=$((bad+1)); return; }
  want="$("$@" | sha)" || { echo "cannot read from bucket: $rel" >&2; bad=$((bad+1)); return; }
  have="$(sha < "$f")"
  if [ "$want" != "$have" ]; then echo "MISMATCH: $rel" >&2; bad=$((bad+1)); return; fi
  if [ "$REMOVE" = 1 ]; then
    saved="$(awk -v r="$rel" '{h=$1; $1=""; sub(/^  ?/,""); if ($0==r) print h}' "$MANIFEST")"
    [ "$saved" = "$have" ] || { echo "NOT IN MANIFEST or changed: $rel" >&2; bad=$((bad+1)); return; }
  fi
  printf '%s  %s\n' "$have" "$rel" >> "$NEWMAN"; checked=$((checked+1))
}
while IFS= read -r k; do
  [ -n "$k" ] || continue
  check "objects/$k" m cat "adm/$BUCKET/$k"
done <<< "$KEYS"
while IFS=$'\t' read -r k vid dm _latest; do
  [ -n "$k" ] && [ "$dm" = false ] || continue
  check "versions/$vid/$k" m cat --version-id "$vid" "adm/$BUCKET/$k"
done <<< "$INV"
n_expect=$(( n_bucket + n_ver - n_dm ))
n_local="$(find "$OBJ" "$VER" -type f 2>/dev/null | grep -c . || true)"
[ "$bad" = 0 ] || die "$bad files failed verification; nothing was removed"
[ "$checked" = "$n_expect" ] || die "verified $checked of $n_expect files"
[ "$n_local" = "$n_expect" ] || die "export holds $n_local files, expected $n_expect; extra or missing files under $DEST"
if [ "$REMOVE" = 1 ]; then
  [ "$(grep -c . "$MANIFEST")" = "$n_expect" ] || die "manifest lists a different number of files than expected ($n_expect)"
else
  cp "$NEWMAN" "$MANIFEST"
fi
echo "verified $checked of $n_expect files by sha256: $n_bucket current objects, $((n_ver - n_dm)) versions (manifest: $MANIFEST)"
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

# `rb --force` removes the bucket with every object, version and delete marker; the export
# above holds all of them.
m rb --force --dangerous "adm/$BUCKET" >/dev/null || die "mc rb failed"
# Read back: the bucket listing must succeed AND omit the bucket. A failed read is not absence.
blist="$(m ls adm)" || die "cannot list buckets after rb; cannot confirm removal"
if printf '%s\n' "$blist" | grep -q "[[:space:]]$BUCKET/\?\$"; then die "bucket still listed after rb"; fi
echo "gone: bucket $BUCKET (bucket listing read back without it)"

# not_found OUTPUT: true only for MinIO's own "no such service account" answer.
not_found(){ printf '%s' "$1" | grep -qiE 'not found|does not exist|no such|NoSuchServiceAccount|specified service account'; }

# Scoped key recorded in Vault. Absent Vault path is fine; any other read error is not.
out="$(vault kv get -format=json "$SVC_PATH" 2>&1)" && rc=0 || rc=$?
if [ "$rc" = 0 ]; then
  AK="$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["data"]["access_key"])')" \
    || die "cannot parse access_key at $SVC_PATH"
  [ -n "$AK" ] || die "empty access_key at $SVC_PATH"
  info="$(m admin user svcacct info adm "$AK" 2>&1)" && irc=0 || irc=$?
  if [ "$irc" = 0 ]; then
    m admin user svcacct rm adm "$AK" >/dev/null || die "cannot remove the scoped MinIO key; $SVC_PATH kept"
    info="$(m admin user svcacct info adm "$AK" 2>&1)" && irc=0 || irc=$?
    [ "$irc" != 0 ] && not_found "$info" || die "cannot confirm the scoped key is revoked: ${info:-still exists}; $SVC_PATH kept"
    echo "gone: scoped MinIO key recorded at $SVC_PATH"
  elif not_found "$info"; then
    echo "absent: scoped MinIO key (MinIO answered not found)"
  else
    die "cannot read the scoped key from MinIO: $info; $SVC_PATH kept"
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
