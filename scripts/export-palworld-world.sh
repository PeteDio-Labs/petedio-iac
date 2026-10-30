#!/usr/bin/env bash
# export-palworld-world.sh — save the live Palworld world to MinIO before CT 234 is
# destroyed, and prove the copy restores. (PET-779)
#
# Run it on 247 on Pedro's word, BEFORE setting ALLOW_DESTROY=true. It stops palworld.service
# on the target so the save is consistent (the game saves on SIGTERM), copies Pal/Saved into
# an archive, uploads it to the palworld-backups bucket, then downloads it again and compares
# checksums. It deletes nothing: every earlier archive in the bucket stays.
#
# The archive keeps the layout restore-palworld-world.sh expects:
#     palworld-final-<ts>/Saved/SaveGames/0/<worldguid>/Level.sav
#
#   ./scripts/export-palworld-world.sh
#   TARGET=192.168.50.234 ./scripts/export-palworld-world.sh
#
# The script leaves palworld.service stopped. The container is about to be destroyed, and the
# unit is disabled by design, so nothing starts it again on its own.
set -euo pipefail

TARGET="${TARGET:-192.168.50.234}"
TARGET_USER="${TARGET_USER:-root}"
TARGET_KEY="${TARGET_KEY:-$HOME/.ssh/id_ed25519_ansible}"
MINIO_URL="${MINIO_URL:-http://192.168.50.221:9000}"
BUCKET="${BUCKET:-palworld-backups}"
SAVED_PARENT="/home/steam/palworld/Pal"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
NAME="palworld-final-${TS}"
ARCHIVE="${NAME}.tar.gz"

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }
sha(){ if command -v sha256sum >/dev/null; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }

command -v mc >/dev/null || die "mc (MinIO client) not found."
[ -f "$TARGET_KEY" ] || die "SSH key not found: $TARGET_KEY"
SSH=(ssh -i "$TARGET_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$TARGET_USER@$TARGET")

step "Resolving minio-221 credentials"
MINIO_USER=""; MINIO_PASS=""
if command -v vault >/dev/null && [ -n "${VAULT_TOKEN:-}" ]; then
  MINIO_USER="$(vault kv get -field=root_user kv/iac/minio-root 2>/dev/null || true)"
  MINIO_PASS="$(vault kv get -field=root_password kv/iac/minio-root 2>/dev/null || true)"
fi
[ -n "$MINIO_USER" ] && [ -n "$MINIO_PASS" ] || die "No minio-221 credential: set VAULT_TOKEN so 'vault kv get kv/iac/minio-root' works."
export MC_HOST_pal221="http://${MINIO_USER}:${MINIO_PASS}@${MINIO_URL#http://}"
mc ls "pal221/${BUCKET}" >/dev/null || die "Cannot list pal221/${BUCKET}."
echo "  ok (credential held in the environment only)"

step "Checking the world on $TARGET"
"${SSH[@]}" "test -d $SAVED_PARENT/Saved/SaveGames" || die "No SaveGames under $SAVED_PARENT/Saved on $TARGET."
REMOTE_FILES="$("${SSH[@]}" "find $SAVED_PARENT/Saved/SaveGames -type f | wc -l" | tr -d '[:space:]')"
echo "  $REMOTE_FILES save files on the host"
[ "$REMOTE_FILES" -gt 0 ] || die "SaveGames holds no files."

step "Stopping palworld.service for a consistent save"
"${SSH[@]}" "systemctl stop palworld; systemctl is-active palworld || true"
"${SSH[@]}" "! systemctl is-active --quiet palworld" || die "palworld.service is still active."

step "Archiving Pal/Saved"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
"${SSH[@]}" "tar czf - --transform 's#^Saved#${NAME}/Saved#' -C $SAVED_PARENT Saved" > "$WORK/$ARCHIVE"
gzip -t "$WORK/$ARCHIVE" || die "archive fails gzip integrity"
LOCAL_FILES="$(tar tzf "$WORK/$ARCHIVE" | grep -c "/SaveGames/.*[^/]$" || true)"
WORLD="$(tar tzf "$WORK/$ARCHIVE" | sed -nE 's#.*SaveGames/0/([0-9A-F]{32})/Level\.sav$#\1#p' | head -1)"
echo "  $(ls -lh "$WORK/$ARCHIVE" | awk '{print $5}'), $LOCAL_FILES save files, world $WORLD"
[ -n "$WORLD" ] || die "No SaveGames/0/<worldguid>/Level.sav inside the archive."
[ "$LOCAL_FILES" -eq "$REMOTE_FILES" ] || die "File count mismatch: host $REMOTE_FILES, archive $LOCAL_FILES."
SUM="$(sha "$WORK/$ARCHIVE")"
echo "$SUM  $ARCHIVE" > "$WORK/$ARCHIVE.sha256"

step "Uploading to pal221/${BUCKET}"
mc stat "pal221/${BUCKET}/${ARCHIVE}" >/dev/null 2>&1 && die "${ARCHIVE} already exists in the bucket."
mc cp --quiet "$WORK/$ARCHIVE" "pal221/${BUCKET}/${ARCHIVE}"
mc cp --quiet "$WORK/$ARCHIVE.sha256" "pal221/${BUCKET}/${ARCHIVE}.sha256"

step "Verifying the stored copy"
mc cp --quiet "pal221/${BUCKET}/${ARCHIVE}" "$WORK/verify.tar.gz"
BACK="$(sha "$WORK/verify.tar.gz")"
[ "$BACK" = "$SUM" ] || die "Stored copy sha256 $BACK differs from the archive $SUM."
gzip -t "$WORK/verify.tar.gz" || die "stored copy fails gzip integrity"
echo "  stored copy matches: $SUM"

step "Done"
cat <<DONE
  archive: pal221/${BUCKET}/${ARCHIVE}  (sha256 sidecar beside it)
  world:   ${WORLD}
  Restore: ARCHIVE=${ARCHIVE} ./scripts/restore-palworld-world.sh  (see docs/runbooks/palworld-restore.md)
  Existing archives in the bucket are untouched.
DONE
