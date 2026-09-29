#!/usr/bin/env bash
# pve02-rescue-stranded-backups.sh — move the vzdump archives that landed on pve02's root
# disk onto ollama-host, then clear the snapshot-delete locks the full disk left. (PET-529)
#
# WHY A SCRIPT AND NOT AN ANSIBLE TASK, which is what workflow rule 6 asks for by default.
# The move is correct exactly once: after it, the stranded directory is empty and the task
# has nothing to converge. The lasting fix is Ansible: roles/backup-store sets
# is_mountpoint on the store, so an unmounted share fails the job instead of filling root.
#
# WHAT HAPPENED. mnt-ollama\x2dbackups.mount timed out at boot on 2026-09-14. The fstab line
# is nofail, so /mnt/ollama-backups stayed an ordinary directory on the root disk, Proxmox
# kept reporting the store active, and every nightly vzdump wrote there until root held 0
# bytes free. The full disk then left 110, 233 and 236 locked `snapshot-delete`.
#
# WHAT IT DOES, in order. Nothing is deleted before step 5, and only per file.
#   1. Bind-mounts / at a scratch path under /run, so the stranded files stay readable
#      after the NFS share is mounted over /mnt/ollama-backups.
#   2. Checksums every stranded file on the local disk (sha256).
#   3. Mounts the share through its systemd unit and checks it is NFS with room to spare.
#   4. Copies each file into a staging directory on the share, then renames it into place,
#      so Proxmox never lists a half-copied archive. A file that already exists on the
#      share is not overwritten: a matching checksum counts as copied, a different one is
#      kept on pve02 and reported.
#   5. Drops the page cache, re-reads each copy from the share, and deletes the local file
#      only when that checksum equals the local one.
#   6. Clears the locks: `pct unlock`, then `pct delsnapshot <id> vzdump`. Never --force,
#      which removes the config entry even when the LVM snapshot survives.
#
# Run it as root on pve02. It is safe to re-run: every step reads state before acting.
#
#   DRY_RUN=1 bash /run/pet529.sh     # steps 1 and 2 only; lists the files, changes nothing
#   bash /run/pet529.sh
#
# Exit status: 0 when root has free space, the share is mounted and all three locks are
# clear. Non-zero otherwise, with each problem printed as FAIL.
set -euo pipefail

MNT=/mnt/ollama-backups
UNIT='mnt-ollama\x2dbackups.mount'
CTS=(110 233 236)
WORK=/run/pet529
ROOTVIEW=$WORK/root
STAGE_NAME=.pet529-staging
DRY_RUN="${DRY_RUN:-0}"

fails=0
say()  { printf '%s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }
die()  { printf 'ABORT %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root"
[[ $(hostname -s) == pve02 ]] || die "this is $(hostname -s), not pve02"
for bin in pct findmnt sha256sum systemctl lvs; do
  command -v "$bin" >/dev/null || die "missing $bin"
done

cleanup() {
  if findmnt -rn "$ROOTVIEW" >/dev/null 2>&1; then umount -R "$ROOTVIEW" || true; fi
}
trap cleanup EXIT

say "== root disk before"
df -h /

# ------------------------------------------------------------ 1. root view --
# /run is tmpfs, so this works with 0 bytes free on root. A plain (non-recursive) bind
# shows the root filesystem alone, including the directory under any mount at $MNT.
# ⚠ / is a shared mount (systemd's default), so a bind of it joins the same peer group, and
# the NFS mount in step 3 propagated into the view and hid the stranded files (the first run,
# 2026-09-28). Make the view private before anything mounts. A view left by an earlier run
# can carry that propagated share, so start from a fresh one.
mkdir -p "$ROOTVIEW"
if findmnt -rn "$ROOTVIEW" >/dev/null; then umount -R "$ROOTVIEW"; fi
mount --bind -o ro / "$ROOTVIEW"
mount --make-private "$ROOTVIEW"
[[ $(findmnt -no PROPAGATION "$ROOTVIEW") == private ]] || die "$ROOTVIEW is not private"
if findmnt -rn -o TARGET | grep -qF "$ROOTVIEW/"; then die "$ROOTVIEW has submounts"; fi
LOCAL="$ROOTVIEW$MNT"
[[ -d $LOCAL ]] || die "$LOCAL does not exist on the root filesystem"

mapfile -t FILES < <(cd "$LOCAL" && find . -type f ! -name '.write-test-*' ! -path "./dump/$STAGE_NAME/*" -printf '%P\n' | sort)
say "== ${#FILES[@]} stranded files under $MNT on the root disk"
if [[ ${#FILES[@]} -gt 0 ]]; then
  (cd "$LOCAL" && du -ch -- "${FILES[@]}" | tail -1)
  (cd "$LOCAL" && ls -l --time-style=+%F -- "${FILES[@]}")
fi

# -------------------------------------------------------- 2. local checksums --
SUMS=$WORK/local.sha256
if [[ ${#FILES[@]} -gt 0 ]]; then
  say "== checksumming locally (reads every byte; minutes for tens of GB)"
  (cd "$LOCAL" && sha256sum -- "${FILES[@]}") > "$SUMS"
  say "wrote $SUMS"
fi

if [[ $DRY_RUN == 1 ]]; then
  say "== DRY_RUN=1: stopping before any change"
  exit 0
fi

# The bind was read-only for the checksums. Deleting needs it writable.
mount -o remount,bind,rw "$ROOTVIEW"

# ------------------------------------------------------------- 3. the share --
if ! findmnt -no FSTYPE "$MNT" | grep -q '^nfs'; then
  say "== starting $UNIT"
  systemctl reset-failed "$UNIT" || true
  systemctl start "$UNIT"
fi
FSTYPE=$(findmnt -no FSTYPE "$MNT" || true)
[[ $FSTYPE == nfs* ]] || die "$MNT is '$FSTYPE' after starting $UNIT, not NFS"
say "== $MNT is $FSTYPE from $(findmnt -no SOURCE "$MNT")"

if [[ ${#FILES[@]} -gt 0 ]]; then
  NEED=$(cd "$LOCAL" && du -cb -- "${FILES[@]}" | tail -1 | cut -f1)
  HAVE=$(df -B1 --output=avail "$MNT" | tail -1 | tr -d ' ')
  (( HAVE > NEED + NEED / 10 )) || die "share has $HAVE bytes free, need $NEED plus 10%"
fi

# ------------------------------------------------------ 4. copy, 5. verify --
declare -A COPIED=()
for f in "${FILES[@]}"; do
  dest="$MNT/$f"
  if [[ -e $dest ]]; then
    COPIED[$f]=existing
    continue
  fi
  stage="$MNT/$(dirname "$f")/$STAGE_NAME"
  mkdir -p "$stage"
  say "copy $f"
  cp --preserve=mode,timestamps -- "$LOCAL/$f" "$stage/$(basename "$f")"
  mv -- "$stage/$(basename "$f")" "$dest"
  COPIED[$f]=new
done
find "$MNT" -maxdepth 2 -type d -name "$STAGE_NAME" -empty -delete || true

if [[ ${#FILES[@]} -gt 0 ]]; then
  # Without this, sha256sum would read the copies back from this node's page cache and
  # prove only that the kernel remembers what it wrote.
  sync
  echo 3 > /proc/sys/vm/drop_caches
  say "== verifying copies as the share returns them"
fi

moved=0 kept=0
while read -r sum name; do
  f="${name#\*}"
  remote=$(sha256sum -- "$MNT/$f" 2>/dev/null | cut -d' ' -f1) || remote="unreadable"
  if [[ $remote == "$sum" ]]; then
    rm -- "$LOCAL/$f"
    say "ok   $f (${COPIED[$f]:-?}, checksum matches, local copy deleted)"
    moved=$((moved + 1))
  else
    fail "$f: the share holds different content ($remote), local copy KEPT"
    kept=$((kept + 1))
  fi
done < <([[ -s $SUMS ]] && cat "$SUMS")
say "== moved $moved, kept $kept"

say "== root disk after"
df -h /

# -------------------------------------------------------------- 6. the locks --
# After the cleanup, not before: pmxcfs keeps its database on this root disk, so a
# config write can fail while it is full.
for id in "${CTS[@]}"; do
  lock=$(pct config "$id" | sed -n 's/^lock: //p')
  if [[ $lock == snapshot-delete ]]; then
    say "== $id: clearing lock snapshot-delete"
    pct unlock "$id"
  elif [[ -n $lock ]]; then
    fail "$id: lock is '$lock', not snapshot-delete; left alone"
    continue
  fi
  if pct listsnapshot "$id" | grep -qw vzdump; then
    if pct delsnapshot "$id" vzdump; then
      say "ok   $id: vzdump snapshot deleted"
    else
      fail "$id: delsnapshot failed; its LVM volumes follow"
      lvs --noheadings -o lv_name,lv_attr,origin pve | grep -E "vm-$id-" || true
    fi
  else
    say "ok   $id: no vzdump snapshot"
  fi
done

# ------------------------------------------------------------------- verdict --
say "== verdict"
avail=$(df -B1 --output=avail / | tail -1 | tr -d ' ')
if (( avail > 0 )); then say "ok   root has $(df -h --output=avail / | tail -1 | tr -d ' ') free"
else fail "root still has 0 bytes free"; fi
FSTYPE=$(findmnt -no FSTYPE "$MNT" || true)
if [[ $FSTYPE == nfs* ]]; then say "ok   $MNT is mounted ($FSTYPE)"
else fail "$MNT is not mounted"; fi
for id in "${CTS[@]}"; do
  lock=$(pct config "$id" | sed -n 's/^lock: //p')
  if [[ -z $lock ]]; then say "ok   $id unlocked"
  else fail "$id still has lock '$lock'"; fi
done
pvesm status --storage ollama-backups || true
if [[ -d /var/tmp/vzdump ]]; then
  say "== leftover vzdump scratch, not touched:"
  du -sh /var/tmp/vzdump
fi

(( fails == 0 )) || { say "== $fails problem(s) above"; exit 1; }
say "== done"
