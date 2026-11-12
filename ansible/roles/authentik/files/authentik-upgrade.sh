#!/bin/sh
# authentik-upgrade.sh — move the Authentik compose stack to one version, safely (PET-908).
# The authentik role pipes it into `pct exec 119 -- sh -s <plan|apply> <version>`.
#
#   plan   reads the tag and the container health, decides, changes nothing
#   apply  backs up the compose file and the database, edits the tag, pulls, then recreates
#          server, worker and ldap one at a time, waiting for each to report healthy
#
# It refuses: a version that is not YYYY.M.P, a downgrade, a jump of more than one minor, a stack
# whose services are not all healthy, and a compose file whose server, worker and ldap images do
# not share one tag. If a service does not come back healthy it restores the compose file and
# exits non-zero. The restore returns the image only. A migration that already ran stays, so a
# failed upgrade past a migration recovers from the vzdump archive the play takes first.
#
# Prints no secret. The last line is `RESULT|<mode>|<current>|<wanted>|<action>`.
set -eu

MODE=${1:-}; WANT=${2:-}
DIR=/opt/authentik; F=$DIR/docker-compose.yml
case "$MODE" in plan|apply) ;; *) echo "REFUSED: mode must be plan or apply" >&2; exit 2 ;; esac
printf '%s' "$WANT" | grep -Eq '^20[0-9]{2}\.[0-9]{1,2}\.[0-9]+$' || { echo "REFUSED: version must look like 2024.12.5" >&2; exit 2; }
[ -r "$F" ] || { echo "ERR $F is missing" >&2; exit 1; }

# The minors Authentik ships in order, from the release notes read on 2026-11-12. A version
# outside the list is refused, so the list is the review point for each new minor.
ORDER="2024.12 2025.2 2025.4 2025.6 2025.8 2025.10 2025.12 2026.2 2026.5 2026.8"
idx() { i=0; for m in $ORDER; do [ "$m" = "$1" ] && { echo $i; return; }; i=$((i+1)); done; echo -1; }
minor() { printf '%s' "$1" | cut -d. -f1,2; }

tags=$(grep -E '^[[:space:]]*image:[[:space:]]*ghcr\.io/goauthentik/(server|ldap):' "$F" | sed -E 's/.*://' | tr -d ' \r' | sort -u)
[ "$(printf '%s\n' "$tags" | grep -c .)" -eq 1 ] || { echo "ERR server and ldap images do not share one tag" >&2; exit 1; }
CUR=$tags
ci=$(idx "$(minor "$CUR")"); wi=$(idx "$(minor "$WANT")")
[ "$ci" -ge 0 ] && [ "$wi" -ge 0 ] || { echo "REFUSED: $(minor "$CUR") or $(minor "$WANT") is not in the reviewed minor list" >&2; exit 2; }
[ "$wi" -ge "$ci" ] && [ $((wi - ci)) -le 1 ] || { echo "REFUSED: move at most one minor forward" >&2; exit 2; }
[ "$(printf '%s\n%s\n' "$CUR" "$WANT" | sort -V | tail -1)" = "$WANT" ] || { echo "REFUSED: downgrade" >&2; exit 2; }

health() {  # prints the number of containers that are not healthy
  bad=0
  [ "$(docker compose -f "$F" ps -aq | grep -c .)" -ge 5 ] || { echo 99; return; }
  for c in $(docker compose -f "$F" ps -aq); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' "$c" 2>/dev/null)" = healthy ] || bad=$((bad+1))
  done
  echo $bad
}
[ "$(docker compose -f "$F" ps -aq | grep -c .)" -ge 5 ] || { echo "ERR fewer than 5 compose containers" >&2; exit 1; }
[ "$(health)" -eq 0 ] || { echo "ERR a container is not healthy; fix it first" >&2; exit 1; }

if [ "$CUR" = "$WANT" ]; then echo "RESULT|$MODE|$CUR|$WANT|noop"; exit 0; fi
if [ "$MODE" = plan ]; then echo "RESULT|plan|$CUR|$WANT|bump"; exit 0; fi

TS=$(date -u +%Y%m%dT%H%M%SZ)
cp -p "$F" "$F.pre-$WANT-$TS"
DUMP=/root/authentik-pre-$WANT-$TS.sql
# POSTGRES_USER and POSTGRES_DB are read inside the container, so no credential passes here.
# The dump goes to a file first, so a pg_dump failure is the exit status of this command and not
# hidden behind a pipe. </dev/null keeps `exec` from reading the rest of this script from stdin.
docker compose -f "$F" exec -T postgresql sh -c 'pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB"' </dev/null > "$DUMP" \
  && tail -n 5 "$DUMP" | grep -q 'PostgreSQL database dump complete' \
  && [ "$(grep -c '^CREATE TABLE' "$DUMP")" -gt 100 ] \
  || { rm -f "$DUMP"; echo "ERR database dump failed its check" >&2; exit 1; }
gzip -f "$DUMP"

sed -i -E "s#(image:[[:space:]]*ghcr\.io/goauthentik/(server|ldap)):$CUR#\1:$WANT#" "$F"
# Before any container is recreated, a failure only needs the compose file put back.
rollback() { cp -p "$F.pre-$WANT-$TS" "$F"; echo "ROLLED_BACK compose file; no container recreated: $1" >&2; exit 1; }
[ "$(grep -E '^[[:space:]]*image:[[:space:]]*ghcr\.io/goauthentik/(server|ldap):' "$F" | sed -E 's/.*://' | tr -d ' \r' | sort -u)" = "$WANT" ] || rollback "tag edit did not take"
docker compose -f "$F" config -q || rollback "compose config"
docker compose -f "$F" pull -q server worker ldap >/dev/null 2>&1 || rollback "pull"

for svc in server worker ldap; do
  if [ "$svc" = server ]; then
    docker compose -f "$F" up -d --no-deps "$svc" >/dev/null 2>&1 || rollback "up $svc"
  else
    docker compose -f "$F" up -d --no-deps "$svc" >/dev/null 2>&1 || { echo "ERR up $svc failed after server was recreated; compose file left at $WANT" >&2; exit 1; }
  fi
  # 300 s, because the server runs database migrations on its first start. A timeout leaves the
  # stack and the compose file as they are: putting the old image back against a half-migrated
  # database is worse than a slow start. A person reads the logs, then restores from the archive.
  n=0
  until [ "$(health)" -eq 0 ]; do
    n=$((n+1)); [ $n -le 60 ] || { echo "ERR $svc not healthy after 300 s; nothing was rolled back" >&2; exit 1; }
    sleep 5
  done
done
for svc in server worker ldap; do
  cid=$(docker compose -f "$F" ps -q "$svc") && [ -n "$cid" ] || { echo "ERR $svc has no container" >&2; exit 1; }
  img=$(docker inspect -f '{{.Config.Image}}' "$cid") || { echo "ERR cannot inspect $svc" >&2; exit 1; }
  case "$img" in *:"$WANT") ;; *) echo "ERR $svc runs a different tag than $WANT" >&2; exit 1 ;; esac
done
echo "RESULT|apply|$CUR|$WANT|bumped"
