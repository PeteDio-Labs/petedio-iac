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
#   2. Already converged: the image matches, the command has no `--token` and has `--metrics`, the
#      env file exists, the container runs, and /ready answers. Then change nothing. When the
#      configuration matches but the container is stopped or not ready, start it and wait for /ready.
#      It exits 1 when /ready still does not answer, so a dead tunnel never reports success.
#   3. Start the candidate <name>-new with `--env-file` and `--metrics`, keeping the old
#      `--edge-ip-version` and `--protocol` values. It publishes no host port, so it cannot collide
#      with the old connector, which may already hold <bind>:<port>. Probe its /ready by container IP.
#      When it never answers, remove it and exit 1. The old connector is untouched.
#   4. The candidate now carries the tunnel. Stop the old connector, keep it as <name>-prev, and start
#      the final <name> with <bind>:<port> published. Wait for /ready there. When it never answers,
#      remove it, restart <name>-prev, and exit 1. The candidate kept the tunnel up throughout.
#   5. Remove the candidate. At every step at least one connector is connected.
#
# Rollback after a good run: `docker rm -f <name>; docker rename <name>-prev <name>; docker start <name>`.
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

# Wait until http://<host>:<port>/ready answers 200. Returns 1 when it never does.
wait_ready() {
  i=0
  while [ "$i" -lt "$tries" ]; do
    if wget -qO- "http://$1:$port/ready" 2>/dev/null | grep -q '"status":200'; then
      return 0
    fi
    i=$((i + 1))
    sleep "$nap"
  done
  return 1
}

cur_image=$(docker inspect --format '{{.Config.Image}}' "$name")
cur_cmd=$(docker inspect --format '{{json .Config.Cmd}}' "$name")
cur_state=$(docker inspect --format '{{.State.Status}}' "$name")

if [ "$cur_image" = "$image" ] && [ -s "$envfile" ] &&
  ! echo "$cur_cmd" | grep -q '"--token"' && echo "$cur_cmd" | grep -q '"--metrics"'; then
  if [ "$cur_state" != running ]; then
    docker start "$name" >/dev/null
    say "started $name, it was $cur_state"
  fi
  if wait_ready "$bind"; then
    [ "$cur_state" = running ] && say "already converged image=$cur_image" || say "recovered image=$cur_image"
    exit 0
  fi
  say "ERROR $name matches the managed configuration but /ready does not answer on $bind:$port"
  exit 1
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

# Candidate: no published port, probed by its bridge address.
docker rm -f "$new" >/dev/null 2>&1 || true
docker run -d --name "$new" --restart unless-stopped --env-file "$envfile" "$image" "$@" >/dev/null
say "started $new image=$image edge=${edge:-default} protocol=${proto:-default}"
cand_ip=$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$new")
if [ -z "$cand_ip" ] || ! wait_ready "$cand_ip"; then
  docker rm -f "$new" >/dev/null 2>&1 || true
  say "ERROR $new reported no ready connection after $tries tries; old connector left running"
  exit 1
fi
say "$new ready"

# Hand over: the candidate carries the tunnel while the final connector takes the stable port.
docker stop "$name" >/dev/null
docker rm -f "$prev" >/dev/null 2>&1 || true
docker rename "$name" "$prev"
if ! docker run -d --name "$name" --restart unless-stopped --env-file "$envfile" -p "$bind:$port:$port" "$image" "$@" >/dev/null ||
  ! wait_ready "$bind"; then
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker rename "$prev" "$name"
  docker start "$name" >/dev/null
  docker rm -f "$new" >/dev/null 2>&1 || true
  say "ERROR the final connector did not become ready on $bind:$port; restored the old connector"
  exit 1
fi
docker rm -f "$new" >/dev/null
say "done image=$image old=$prev metrics=$bind:$port"
