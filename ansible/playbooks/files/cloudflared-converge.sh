#!/bin/sh
# cloudflared-converge.sh — replace the cloudflared connector on this host with one that reads its
# token from an env file and serves metrics (PET-718, PET-768). configure-cloudflared-112.yml pipes
# it into `pct exec 112 -- sh -s -- <image> <name> <bind> <port> <envfile>`.
#
# The tunnel is token-managed, so a second connector on the same tunnel is safe: Cloudflare spreads
# traffic over both. The script therefore starts the new connector FIRST, waits until it reports
# ready connections, and only then stops the old one. No public hostname loses its origin.
#
#   1. The env file: when it is missing, copy the token out of the running container's `--token`
#      argument into <envfile> (mode 0600). The token never leaves this host and is never printed.
#   2. Already converged (image matches, no `--token` in the command, a metrics flag): do nothing.
#   3. Start <name>-new with `--env-file` and `--metrics`, keeping the old `--edge-ip-version` and
#      `--protocol` values.
#   4. Wait for /ready. When it never answers, remove <name>-new and exit 1. The old connector is
#      untouched.
#   5. Stop the old connector, keep it stopped as <name>-prev for a rollback, and rename the new one.
#
# Rollback: `docker rm -f <name>; docker rename <name>-prev <name>; docker start <name>`.
set -eu
image=$1
name=$2
bind=$3
port=$4
envfile=$5
tries=${READY_TRIES:-30}
nap=${READY_SLEEP:-2}
new="$name-new"
prev="$name-prev"

say() { echo "CONVERGE $*"; }

cur_image=$(docker inspect --format '{{.Config.Image}}' "$name")
cur_cmd=$(docker inspect --format '{{json .Config.Cmd}}' "$name")

if [ "$cur_image" = "$image" ] && ! echo "$cur_cmd" | grep -q '"--token"' && echo "$cur_cmd" | grep -q '"--metrics"'; then
  say "already converged image=$cur_image"
  exit 0
fi

# Value that follows a flag in the old command line. Empty when the flag is absent.
flag_value() {
  docker inspect --format '{{range .Config.Cmd}}{{println .}}{{end}}' "$name" |
    awk -v f="$1" 'p { print; exit } $0 == f { p = 1 }'
}

if [ ! -s "$envfile" ]; then
  token=$(flag_value --token)
  if [ -z "$token" ]; then
    say "ERROR no token in $envfile and none in the running command"
    exit 1
  fi
  mkdir -p "$(dirname "$envfile")"
  (umask 077 && printf 'TUNNEL_TOKEN=%s\n' "$token" > "$envfile")
  chmod 600 "$envfile"
  say "wrote $envfile (mode 0600, token not printed)"
fi
[ -s "$envfile" ] || { say "ERROR $envfile is empty"; exit 1; }

edge=$(flag_value --edge-ip-version)
proto=$(flag_value --protocol)
set -- tunnel --no-autoupdate --metrics "0.0.0.0:$port"
[ -z "$edge" ] || set -- "$@" --edge-ip-version "$edge"
[ -z "$proto" ] || set -- "$@" --protocol "$proto"
set -- "$@" run

docker rm -f "$new" >/dev/null 2>&1 || true
docker run -d --name "$new" --restart unless-stopped --env-file "$envfile" -p "$bind:$port:$port" "$image" "$@" >/dev/null
say "started $new image=$image edge=${edge:-default} protocol=${proto:-default}"

ready=0
i=0
while [ "$i" -lt "$tries" ]; do
  if wget -qO- "http://$bind:$port/ready" 2>/dev/null | grep -q '"status":200'; then
    ready=1
    break
  fi
  i=$((i + 1))
  sleep "$nap"
done
if [ "$ready" -ne 1 ]; then
  docker rm -f "$new" >/dev/null 2>&1 || true
  say "ERROR $new reported no ready connection after $tries tries; old connector left running"
  exit 1
fi
say "$new ready"

docker stop "$name" >/dev/null
docker rm -f "$prev" >/dev/null 2>&1 || true
docker rename "$name" "$prev"
docker rename "$new" "$name"
say "done image=$image old=$prev metrics=$bind:$port"
