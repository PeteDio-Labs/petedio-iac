#!/bin/sh
# cloudflared-audit.sh — print how each container on this host is configured, with no secret in
# the output (PET-768, PET-718). audit-cloudflared-112.yml pipes it into `pct exec 112 -- sh -s`.
#
# The tunnel token can sit in Config.Cmd (`--token <value>`) or in Config.Env (`TUNNEL_TOKEN=...`).
# This script strips the secret here, on the guest, so no raw value reaches Ansible's registered
# result, its verbose output or the public run log:
#   - Env: only each variable's NAME is printed (text before the first `=`).
#   - Entrypoint and Cmd: a flag prints its name without any `=value`; a word that is not a flag
#     prints only when it is on the allowlist below, otherwise `<arg>`.
# It exits non-zero when any inspect fails, and its last line says how many containers it listed
# and how many it inspected, so a partial read cannot look like a full one.
set -eu

ids=$(docker ps -aq)
listed=0
inspected=0
for id in $ids; do
  listed=$((listed + 1))
  # Each inspect runs in an assignment, so `set -e` stops the script when it fails. A pipe into awk
  # would hide that failure behind awk's status. `json` escapes a newline inside a value, so each
  # argument and each variable is exactly one line before anything is filtered.
  meta=$(docker inspect --format \
    'CONTAINER {{.Name}}|image={{.Config.Image}}|restart={{.HostConfig.RestartPolicy.Name}}|network={{.HostConfig.NetworkMode}}|state={{.State.Status}}' \
    "$id")
  args=$(docker inspect --format '{{range .Config.Entrypoint}}{{json .}}{{"\n"}}{{end}}{{range .Config.Cmd}}{{json .}}{{"\n"}}{{end}}' "$id")
  envs=$(docker inspect --format '{{range .Config.Env}}{{json .}}{{"\n"}}{{end}}' "$id")
  echo "$meta"
  printf '%s\n' "$args" | awk '
    NF == 0 { next }
    /^"-/ { sub(/^"/, ""); sub(/=.*/, ""); sub(/"$/, ""); print "  ARG " $0; next }
    /^"(tunnel|run|update|version|info|debug|warn|error|fatal|cloudflared)"$/ { gsub(/"/, ""); print "  ARG " $0; next }
    { print "  ARG <arg>" }'
  printf '%s\n' "$envs" | awk '
    NF == 0 { next }
    { sub(/^"/, ""); sub(/=.*/, ""); sub(/"$/, ""); print "  ENV " $0 }'
  inspected=$((inspected + 1))
done
echo "AUDIT listed=$listed inspected=$inspected"
