#!/usr/bin/env bash
# restore-palworld-world.sh — put the saved Palworld world onto a fresh game host. (PET-381)
#
# WHY A SCRIPT AND NOT AN ANSIBLE TASK, which is what workflow rule 6 asks for by default.
# Recorded verbatim so nobody re-litigates it:
#
#   A restore is correct EXACTLY ONCE. Every converge after it must not run, because by
#   then the world is live and re-extracting a July archive over it destroys everything
#   played since. Expressing that as a converge task means a permanent guard whose only
#   job is to make the task never run again — and a task that must never fire is not
#   configuration, it is a landmine with a safety catch.
#
#   It would also mean parking MinIO root credentials on the game host, permanently, in a
#   play that runs on every merge, to serve an operation that is over.
#
#   So: config stays in Ansible (the role installs the game, pins DedicatedServerName,
#   opens the port); this one-shot stays here, guarded, verified, and operator-run.
#
# ⚠ IT WILL NOT OVERWRITE A LIVE WORLD. If SaveGames already exists on the target the
# script refuses and exits non-zero. Override only with FORCE=1, and only if you genuinely
# mean to discard what is on that host.
#
# ⚠ IT DOES NOT START THE SERVER. Starting it is the moment the world becomes writable,
# and it is the operator's call. Verify worldguid first — see the end of this script.
#
#   ./scripts/restore-palworld-world.sh
#   TARGET=192.168.50.234 ARCHIVE=palworld-final-20260723T011311Z.tar.gz ./scripts/...
set -euo pipefail

TARGET="${TARGET:-192.168.50.234}"
TARGET_USER="${TARGET_USER:-root}"
TARGET_KEY="${TARGET_KEY:-$HOME/.ssh/id_ed25519_ansible}"
MINIO_URL="${MINIO_URL:-http://192.168.50.221:9000}"
BUCKET="${BUCKET:-palworld-backups}"
# The LATER of the two archives taken on the PET-266 cutover night. Its sibling,
# palworld-backup-20260723T001041Z.tar.gz, is an hour older — same world, less of it.
ARCHIVE="${ARCHIVE:-palworld-final-20260723T011311Z.tar.gz}"
SAVED_DIR="/home/steam/palworld/Pal/Saved"

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }

command -v mc >/dev/null || die "mc (MinIO client) not found. brew install minio/stable/mc"
[ -f "$TARGET_KEY" ] || die "SSH key not found: $TARGET_KEY"
SSH=(ssh -i "$TARGET_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$TARGET_USER@$TARGET")

step "Resolving minio-221 credentials"
# Vault first; the plaintext file is legacy and pet-secrets doctor already flags it.
# Neither value is ever echoed, written to a new file, or passed on a command line where
# it would show up in the target's process list.
MINIO_USER=""; MINIO_PASS=""
if command -v vault >/dev/null && [ -n "${VAULT_TOKEN:-}" ]; then
  MINIO_USER="$(vault kv get -field=root_user kv/iac/minio-root 2>/dev/null || true)"
  MINIO_PASS="$(vault kv get -field=root_password kv/iac/minio-root 2>/dev/null || true)"
fi
if [ -z "$MINIO_PASS" ]; then
  SECRETS_FILE="${SECRETS_FILE:-$(dirname "$0")/../../.secrets/minio-221.txt}"
  [ -f "$SECRETS_FILE" ] || die "No credentials: Vault unavailable and $SECRETS_FILE missing."
  MINIO_USER="$(awk -F': *' '/root user/{print $2; exit}' "$SECRETS_FILE" | tr -d '[:space:]')"
  MINIO_PASS="$(awk -F': *' '/root pw/{print $2; exit}' "$SECRETS_FILE" | tr -d '[:space:]')"
  [ -n "$MINIO_USER" ] || MINIO_USER="$(awk 'NR==2{print $1}' "$SECRETS_FILE" | tr -d '[:space:]')"
fi
[ -n "$MINIO_PASS" ] || die "Could not resolve the minio-221 root password."

# MC_HOST_<alias> configures mc from the environment, so this writes no ~/.mc/config.json
# and leaves no credential behind when the shell exits.
export MC_HOST_pal221="http://${MINIO_USER}:${MINIO_PASS}@${MINIO_URL#http://}"
echo "  ok (credential held in the environment only)"

step "Refusing to clobber a live world"
# ⚠ THE GUARD THAT MATTERS. `pct`-fresh hosts have no SaveGames; a host that has been
# played on does. Restoring over the second one silently destroys everything since July.
if "${SSH[@]}" "test -d $SAVED_DIR/SaveGames" 2>/dev/null; then
  if [ "${FORCE:-0}" != "1" ]; then
    "${SSH[@]}" "ls -la $SAVED_DIR/SaveGames/0/ 2>/dev/null | head" || true
    die "$TARGET already has $SAVED_DIR/SaveGames. That is a world someone may have played. Re-run with FORCE=1 only if you mean to discard it."
  fi
  printf '\033[1;33m  FORCE=1 — the existing world WILL be replaced.\033[0m\n'
else
  echo "  no SaveGames on $TARGET — clean restore"
fi

step "Fetching $ARCHIVE"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mc cp --quiet "pal221/${BUCKET}/${ARCHIVE}" "$WORK/$ARCHIVE" || die "download failed"
mc cp --quiet "pal221/${BUCKET}/${ARCHIVE}.sha256" "$WORK/$ARCHIVE.sha256" 2>/dev/null || true
ls -lh "$WORK/$ARCHIVE" | awk '{print "  "$5"  "$9}'

step "Verifying the archive"
# ⚠ VERIFY THE BYTES, NOT THE TRANSFER. MinIO stores parts with interleaved bitrot hashes,
# so a hand-assembled copy of this object fails `gzip -t` while looking the right size —
# that is how the first attempt at reading it went wrong. Read through the S3 API and then
# prove the result.
if [ -s "$WORK/$ARCHIVE.sha256" ]; then
  EXPECTED="$(tr -d '\r\n' < "$WORK/$ARCHIVE.sha256" | awk '{print $1}')"
  ACTUAL="$(shasum -a 256 "$WORK/$ARCHIVE" | awk '{print $1}')"
  [ "$EXPECTED" = "$ACTUAL" ] || die "sha256 MISMATCH — expected $EXPECTED, got $ACTUAL"
  echo "  sha256 matches the stored sidecar"
else
  printf '\033[1;33m  no .sha256 sidecar retrieved — falling back to gzip integrity only\033[0m\n'
fi
gzip -t "$WORK/$ARCHIVE" || die "archive fails gzip integrity"
echo "  gzip OK"

step "What is in it"
tar tzf "$WORK/$ARCHIVE" | head -12
echo "  ..."
WORLD_IN_ARCHIVE="$(tar tzf "$WORK/$ARCHIVE" | sed -nE 's#.*SaveGames/0/([0-9A-F]{32})/.*#\1#p' | head -1)"
echo "  world folder in archive: ${WORLD_IN_ARCHIVE:-<none found>}"
[ -n "$WORLD_IN_ARCHIVE" ] || die "No SaveGames/0/<worldguid>/ inside the archive — this is not a world backup."

step "Restoring onto $TARGET"
"${SSH[@]}" "mkdir -p $SAVED_DIR" || die "cannot create $SAVED_DIR"
# Stream it rather than staging a second copy on the target's disk.
gzip -dc "$WORK/$ARCHIVE" | "${SSH[@]}" "tar xf - -C $SAVED_DIR --strip-components=0" \
  || die "extract failed"
"${SSH[@]}" "chown -R steam:steam /home/steam/palworld/Pal/Saved" || die "chown failed"
echo "  extracted and owned by steam"

step "Confirming what landed"
"${SSH[@]}" "ls -la $SAVED_DIR/SaveGames/0/ | head; echo; grep -o 'DedicatedServerName=[A-Za-z0-9]*' $SAVED_DIR/Config/LinuxServer/GameUserSettings.ini 2>/dev/null || echo '(no DedicatedServerName in the restored GameUserSettings.ini — the Ansible role pins it)'"

cat <<EOF

$(printf '\033[1;32mRestored.\033[0m') The world folder is $WORLD_IN_ARCHIVE.

⚠ NOTHING HAS BEEN STARTED, and the next step is the one that has silently failed before.
Copying SaveGames does NOT select the world: the server reads DedicatedServerName from
Pal/Saved/Config/LinuxServer/GameUserSettings.ini, and a host that generates its own world
boots THAT one and comes up fully green on an empty map.

  1. Converge so the role pins DedicatedServerName:
       cd ansible && ansible-playbook -i inventory/ playbooks/configure-palworld.yml
  2. Start it:  ssh $TARGET_USER@$TARGET systemctl start palworld
  3. VERIFY — this is the only check that counts:
       curl -su admin:<AdminPassword> http://$TARGET:8212/v1/api/info
     Expect worldguid $WORLD_IN_ARCHIVE and a non-zero day count.
     days:0 / basecampnum:0 means a fresh world — STOP before it writes.
EOF
