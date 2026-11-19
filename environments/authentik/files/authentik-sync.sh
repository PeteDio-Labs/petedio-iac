#!/bin/bash
# authentik-sync.sh — converge the Authentik host from its bucket (PET-932).
#
# A systemd timer runs this every two minutes. Terraform owns everything it reads:
#   s3://$BUCKET/config/        compose file, settings.env, this script, the backup script
#   SSM $PARAM_PREFIX/env       Authentik's .env, copied from LXC 119 (SecureString)
#   SSM $PARAM_PREFIX/tunnel_token          the authentik-aws tunnel token (SecureString)
#   SSM $PARAM_PREFIX/tailscale_authkey     optional; joins the tailnet once
#   s3://$BUCKET/migrate/       the database dump and media from LXC 119, with a READY stamp
# scripts/seed-authentik-aws.sh writes the parameters and the migrate/ objects, and Pedro runs it.
#
# Safe by default:
#   - It never starts an empty Authentik. A fresh install serves its initial-setup flow to anyone
#     who reaches it, so the stack stays down until the first database copy is restored.
#   - It restores a newer copy only while settings.env says ACCEPT_RESTORE=true. Terraform sets
#     that false in the change that moves auth.pdlab.dev here.
#   - Waiting is exit 0 with a "waiting:" line; any failed read or command is exit 1, so
#     `systemctl status authentik-sync` and the journal show it.
# Every run writes state/status.json with what it examined, for the failover watchdog.
set -euo pipefail
umask 077

: "${BUCKET:?}" "${AWS_REGION:?}"
D=/opt/authentik
S="$D/state"
install -d -m 0700 "$D/config" "$S" "$D/media" "$D/certs" "$D/custom-templates"
export AWS_REGION
log() { echo "authentik-sync: $*"; }

status() { # $1 phase, $2 detail
  local health
  health="$(docker inspect -f '{{.State.Health.Status}}' authentik-server-1 2>/dev/null || echo absent)"
  printf '{"checked_at":"%s","phase":"%s","detail":"%s","server_health":"%s","restored_stamp":"%s","accept_restore":"%s"}\n' \
    "$(date -u +%FT%TZ)" "$1" "$2" "$health" "$(cat "$S/restored-stamp" 2>/dev/null || true)" "${ACCEPT_RESTORE:-unknown}" \
    > "$S/status.json"
}

# ── 1. Config from the bucket ──────────────────────────────────────────────────────────────────
aws s3 sync "s3://$BUCKET/config/" "$D/config/" --only-show-errors
for f in docker-compose.yml settings.env authentik-sync.sh authentik-backup.sh; do
  [ -s "$D/config/$f" ] || { log "config/$f is missing or empty in s3://$BUCKET. Run the aws-apply for environments/authentik."; status error "config/$f missing"; exit 1; }
done
# shellcheck disable=SC1091
. "$D/config/settings.env"
: "${PARAM_PREFIX:?settings.env sets no PARAM_PREFIX}" "${ACCEPT_RESTORE:?settings.env sets no ACCEPT_RESTORE}"
install -m 0700 "$D/config/authentik-sync.sh" "$D/bin/authentik-sync.sh"   # takes effect next run
install -m 0700 "$D/config/authentik-backup.sh" "$D/bin/authentik-backup.sh"
install -m 0600 "$D/config/docker-compose.yml" "$D/docker-compose.yml"

if [ ! -f /etc/systemd/system/authentik-backup.timer ]; then
  printf '[Unit]\nDescription=Nightly Authentik dump to S3 (PET-932)\nAfter=docker.service\n\n[Service]\nType=oneshot\nEnvironmentFile=/opt/authentik/bootstrap.env\nExecStart=/opt/authentik/bin/authentik-backup.sh\n' \
    > /etc/systemd/system/authentik-backup.service
  printf '[Unit]\nDescription=Run authentik-backup nightly\n\n[Timer]\nOnCalendar=*-*-* 07:30:00 UTC\nPersistent=true\n\n[Install]\nWantedBy=timers.target\n' \
    > /etc/systemd/system/authentik-backup.timer
  systemctl daemon-reload
  systemctl enable --now authentik-backup.timer
  log "installed the nightly backup timer"
fi

# ── 2. Secrets from Parameter Store ────────────────────────────────────────────────────────────
# Prints the value, or nothing when the parameter does not exist. Any other error stops the run.
param() {
  local out err
  err="$(mktemp)"
  if out="$(aws ssm get-parameter --with-decryption --name "$PARAM_PREFIX/$1" --query Parameter.Value --output text 2>"$err")"; then
    printf '%s' "$out"
  elif grep -q ParameterNotFound "$err"; then
    :
  else
    log "reading $PARAM_PREFIX/$1 failed: $(head -c 200 "$err")"
    status error "parameter read failed: $1"
    exit 1
  fi
  shred -u "$err" 2>/dev/null || true
}

envv="$(param env)"
[ -n "$envv" ] || { log "waiting: $PARAM_PREFIX/env is not set. Pedro runs scripts/seed-authentik-aws.sh."; status waiting "no env parameter"; exit 0; }
grep -q '^AUTHENTIK_SECRET_KEY=' <<<"$envv" && grep -q '^PG_PASS=' <<<"$envv" \
  || { log "$PARAM_PREFIX/env holds no AUTHENTIK_SECRET_KEY or PG_PASS line. Re-run the seed script."; status error "env parameter incomplete"; exit 1; }
printf '%s\n' "$envv" > "$D/.env.new"
cmp -s "$D/.env.new" "$D/.env" 2>/dev/null && shred -u "$D/.env.new" || { mv "$D/.env.new" "$D/.env"; log "wrote .env from $PARAM_PREFIX/env"; }
unset envv

tok="$(param tunnel_token)"
[ -n "$tok" ] || { log "waiting: $PARAM_PREFIX/tunnel_token is not set. Pedro runs scripts/seed-authentik-aws.sh."; status waiting "no tunnel token"; exit 0; }
printf 'TUNNEL_TOKEN=%s\n' "$tok" > "$D/.tunnel.env.new"
cmp -s "$D/.tunnel.env.new" "$D/.tunnel.env" 2>/dev/null && shred -u "$D/.tunnel.env.new" || mv "$D/.tunnel.env.new" "$D/.tunnel.env"
unset tok

# Tailscale is optional: the host joins once, with Tailscale SSH, when a key exists.
if [ ! -f "$S/tailscale-joined" ]; then
  tsk="$(param tailscale_authkey)"
  if [ -n "$tsk" ]; then
    if ! command -v tailscale >/dev/null; then
      dnf -y config-manager --add-repo https://pkgs.tailscale.com/stable/amazon-linux/2023/tailscale.repo
      dnf -y install tailscale
      systemctl enable --now tailscaled
    fi
    printf '%s' "$tsk" > "$S/ts.key"
    tailscale up --auth-key="file:$S/ts.key" --hostname=authentik-aws --ssh
    shred -u "$S/ts.key"
    touch "$S/tailscale-joined"
    log "joined the tailnet as authentik-aws"
  fi
  unset tsk
fi

cd "$D"
dc() { docker compose --project-directory "$D" -f "$D/docker-compose.yml" "$@"; }

# ── 3. Restore a database copy from the lab ────────────────────────────────────────────────────
# migrate/READY holds one line: "<stamp> <sha256 of authentik.dump> <sha256 of media.tar.gz>".
ready=""
if aws s3api head-object --bucket "$BUCKET" --key migrate/READY >/dev/null 2>&1; then
  ready="$(aws s3 cp "s3://$BUCKET/migrate/READY" - --only-show-errors)"
fi
have="$(cat "$S/restored-stamp" 2>/dev/null || true)"
stamp="$(awk '{print $1}' <<<"$ready")"

if [ -n "$stamp" ] && [ "$stamp" != "$have" ]; then
  if [ "$ACCEPT_RESTORE" != "true" ]; then
    log "refused: migrate/READY offers copy $stamp, but ACCEPT_RESTORE=$ACCEPT_RESTORE. This host is the live Authentik."
  else
    log "restoring copy $stamp from the lab (had: ${have:-none})"
    status restoring "$stamp"
    aws s3 cp "s3://$BUCKET/migrate/authentik.dump" "$S/restore.dump" --only-show-errors
    aws s3 cp "s3://$BUCKET/migrate/media.tar.gz" "$S/media.tar.gz" --only-show-errors
    [ "$(sha256sum "$S/restore.dump" | cut -d' ' -f1)" = "$(awk '{print $2}' <<<"$ready")" ] \
      || { log "authentik.dump does not match its READY digest. Re-run the seed script."; status error "dump digest mismatch"; exit 1; }
    [ "$(sha256sum "$S/media.tar.gz" | cut -d' ' -f1)" = "$(awk '{print $3}' <<<"$ready")" ] \
      || { log "media.tar.gz does not match its READY digest. Re-run the seed script."; status error "media digest mismatch"; exit 1; }
    dc stop server worker cloudflared 2>/dev/null || true
    dc up -d --wait postgresql
    # The role and database come from .env, inside the container, so no value reaches argv here.
    dc exec -T postgresql sh -c 'dropdb -U "$POSTGRES_USER" --if-exists --force "$POSTGRES_DB" && createdb -U "$POSTGRES_USER" -O "$POSTGRES_USER" "$POSTGRES_DB"'
    dc exec -T postgresql sh -c 'pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --role="$POSTGRES_USER" --exit-on-error' < "$S/restore.dump"
    tables="$(dc exec -T postgresql sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "select count(*) from information_schema.tables where table_schema = '"'"'public'"'"'"')"
    users="$(dc exec -T postgresql sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "select count(*) from authentik_core_user"')"
    [ "${tables:-0}" -gt 50 ] && [ "${users:-0}" -gt 0 ] \
      || { log "the restore left $tables tables and $users users, which is not an Authentik database. Stack stays down."; status error "restore check failed"; exit 1; }
    [ ! -d "$D/media" ] || mv "$D/media" "$S/media.before-$stamp"
    install -d -m 0755 "$D/media"
    tar -xzf "$S/media.tar.gz" -C "$D/media"
    shred -u "$S/restore.dump"
    echo "$stamp" > "$S/restored-stamp"
    have="$stamp"
    log "restored copy $stamp: $tables tables, $users users"
  fi
fi

if [ -z "$have" ]; then
  log "waiting: no database copy restored yet, so the stack stays down. An empty Authentik would serve its initial-setup flow to anyone."
  status waiting "no restored copy"
  exit 0
fi

# ── 4. Converge the stack ──────────────────────────────────────────────────────────────────────
dc up -d --remove-orphans --wait --wait-timeout 300 \
  || { log "docker compose up did not reach healthy within 300 s"; status error "stack not healthy"; exit 1; }
status ok "stack healthy, copy $have"
log "ok: config synced, copy $have, stack healthy"
