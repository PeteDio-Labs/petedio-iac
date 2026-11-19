#!/bin/bash
# authentik-backup.sh — nightly dump of the AWS Authentik to its bucket (PET-932).
# A systemd timer runs it at 07:30 UTC. The bucket keeps backups/ for backup_retention_days.
# It backs up only a host that holds a restored copy, and every failure exits non-zero.
set -euo pipefail
umask 077
: "${BUCKET:?}" "${AWS_REGION:?}"
export AWS_REGION
D=/opt/authentik
S="$D/state"
[ -s "$S/restored-stamp" ] || { echo "authentik-backup: no restored copy on this host, so there is nothing to back up."; exit 0; }
day="$(date -u +%F)"
dc() { docker compose --project-directory "$D" -f "$D/docker-compose.yml" "$@"; }

dc exec -T postgresql sh -c 'pg_dump -Fc -U "$POSTGRES_USER" "$POSTGRES_DB"' > "$S/backup.dump"
size="$(stat -c %s "$S/backup.dump")"
[ "$size" -gt 100000 ] || { echo "authentik-backup: the dump is $size bytes, too small for an Authentik database."; exit 1; }
aws s3 cp "$S/backup.dump" "s3://$BUCKET/backups/$day/authentik.dump" --only-show-errors
tar -czf "$S/backup-media.tar.gz" -C "$D/media" .
aws s3 cp "$S/backup-media.tar.gz" "s3://$BUCKET/backups/$day/media.tar.gz" --only-show-errors
msize="$(stat -c %s "$S/backup-media.tar.gz")"
shred -u "$S/backup.dump"
rm -f "$S/backup-media.tar.gz"
date -u +%FT%TZ > "$S/last-backup"
echo "authentik-backup: wrote backups/$day: database $size bytes, media $msize bytes"
