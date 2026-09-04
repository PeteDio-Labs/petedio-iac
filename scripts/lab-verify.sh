#!/usr/bin/env bash
# lab-verify — prove the homelab works, hop by hop, from outside it.
#
# Every check answers a question about BEHAVIOUR, not configuration. A service
# that is "active" is not a service that works: sonarr answered 200 for hours
# after the outage while holding 171 file records for files that no longer
# existed, and Uptime Kuma reported a burned machine as healthy because a
# monitor still pointed at an address that had been reassigned.
#
#   ./scripts/lab-verify.sh          # full run
#   ./scripts/lab-verify.sh --quiet  # only failures
set -uo pipefail

PVE02=pve02
PVE03=pve03
PI=pi1
QUIET=0; [ "${1:-}" = "--quiet" ] && QUIET=1
PASS=0; FAIL=0; SKIP=0

ok()   { PASS=$((PASS+1)); [ $QUIET -eq 1 ] || printf "  \033[32m✓\033[0m %-42s %s\n" "$1" "${2:-}"; }
bad()  { FAIL=$((FAIL+1)); printf "  \033[31m✗\033[0m %-42s %s\n" "$1" "${2:-}"; }
skip() { SKIP=$((SKIP+1)); [ $QUIET -eq 1 ] || printf "  \033[33m-\033[0m %-42s %s\n" "$1" "${2:-}"; }
sec()  { [ $QUIET -eq 1 ] || printf "\n\033[1m%s\033[0m\n" "$1"; }
on()   { ssh -n -o ConnectTimeout=8 -o BatchMode=yes "$1" "$2" 2>/dev/null; }

sec "Nodes and quorum"
for n in $PVE02 $PVE03; do
  h=$(on $n 'hostname')
  [ -n "$h" ] && ok "$n reachable" "$h" || bad "$n reachable" "no ssh"
done
Q=$(on $PVE02 'pvecm status 2>/dev/null | awk "/Quorate:/{print \$2}"')
[ "$Q" = "Yes" ] && ok "cluster quorate" || bad "cluster quorate" "got '$Q'"
# A QDevice that is registered but not voting gives none of the protection it
# was added for, and the vote count alone does not reveal that.
V=$(on $PVE02 'pvecm status 2>/dev/null | grep -c "A,V,"')
[ "${V:-0}" -ge 2 ] && ok "qdevice voting" "$V nodes see it" || bad "qdevice voting" "nodes report A,NV — qnetd cannot read its certs?"
W=$(on $PVE02 'touch /etc/pve/.verify 2>/dev/null && rm -f /etc/pve/.verify && echo yes')
[ "$W" = "yes" ] && ok "/etc/pve writable" || bad "/etc/pve writable" "lost quorum?"

sec "Storage"
for p in media downloads; do
  H=$(on $PVE02 "zpool list -H -o health $p")
  [ "$H" = "ONLINE" ] && ok "pool $p" "ONLINE" || bad "pool $p" "${H:-missing}"
done
# failmode=continue means a USB hiccup stalls I/O rather than suspending the
# pool and taking the whole stack with it.
for p in media downloads; do
  F=$(on $PVE02 "zpool get -H -o value failmode $p")
  [ "$F" = "continue" ] && ok "failmode $p" || bad "failmode $p" "got '$F'"
done
# setgid inheritance is what lets one app read what another wrote. It fails
# silently, days later, at import time.
G=$(on $PVE02 'touch /mnt/downloads/.vtest 2>/dev/null && stat -c %g /mnt/downloads/.vtest; rm -f /mnt/downloads/.vtest')
[ "$G" = "100000" ] && ok "setgid inheritance" "new files land in group 100000" \
  || bad "setgid inheritance" "new file got group '${G}', arr apps will not read it"

sec "Services answer"
while IFS='|' read -r name url; do
  [ -z "$name" ] && continue
  c=$(on $PVE02 "curl -s -o /dev/null -w '%{http_code}' -m 8 '$url'")
  case "$c" in 2*|3*|401|403) ok "$name" "HTTP $c";; *) bad "$name" "HTTP ${c:-timeout}";; esac
done <<'EOF'
sonarr|http://192.168.50.15:8989/
radarr|http://192.168.50.16:7878/
prowlarr|http://192.168.50.20:9696/
qbittorrent|http://192.168.50.21:8080/
seerr|http://192.168.50.33:5055/
plex|http://192.168.50.236:32400/identity
authentik|http://192.168.50.119:9000/
plane|http://192.168.50.235:8080/
minio|http://192.168.50.221:9001/
flaresolverr|http://192.168.50.150:8191/
EOF
PG=$(on $PVE02 'pct exec 231 -- pg_isready 2>/dev/null | grep -c accepting')
[ "${PG:-0}" -ge 1 ] && ok "postgres" "accepting connections" || bad "postgres" "not accepting"
# Vault speaks HTTPS. The same path over http returns a bare 400 that reads as a
# broken server and is not.
SEAL=$(on $PVE02 "curl -sk -m 8 https://192.168.50.223:8200/v1/sys/seal-status | grep -o '\"sealed\":[a-z]*'")
[ "$SEAL" = '"sealed":false' ] && ok "vault unsealed" || bad "vault" "${SEAL:-unreachable}"

sec "The media pipeline, end to end"
# A root folder the app cannot see is the difference between a library and a
# directory listing.
for e in "104|sonarr|192.168.50.15:8989|/var/lib/sonarr/config.xml" "105|radarr|192.168.50.16:7878|/var/lib/radarr/config.xml"; do
  IFS='|' read -r id nm addr cfg <<< "$e"
  k=$(on $PVE02 "pct exec $id -- cat $cfg 2>/dev/null | grep -o '<ApiKey>[^<]*' | cut -c9-")
  [ -z "$k" ] && { skip "$nm root folders" "no api key"; continue; }
  n=$(on $PVE02 "curl -s -m 10 -H 'X-Api-Key: $k' http://$addr/api/v3/rootfolder | grep -c '\"accessible\": *true'")
  [ "${n:-0}" -ge 1 ] && ok "$nm root folders" "$n accessible" || bad "$nm root folders" "none accessible"
  h=$(on $PVE02 "curl -s -m 10 -H 'X-Api-Key: $k' http://$addr/api/v3/health | grep -c '\"type\":\"error\"'")
  [ "${h:-0}" -eq 0 ] && ok "$nm health" "no errors" || bad "$nm health" "$h error-level issues"
done
# The kill switch is only real if qbit has no network of its own.
NS=$(on $PVE02 "pct exec 110 -- docker inspect qbittorrent --format '{{.HostConfig.NetworkMode}}' 2>/dev/null")
case "$NS" in container:*) ok "qbit inside gluetun netns" "no path out if the tunnel drops";; *) bad "qbit netns" "got '${NS:-unknown}' — traffic may bypass the VPN";; esac
VPN=$(on $PVE02 "pct exec 110 -- docker exec gluetun wget -qO- -T 10 https://api.ipify.org 2>/dev/null")
WAN=$(curl -s -m 10 https://api.ipify.org 2>/dev/null)
if [ -n "$VPN" ] && [ -n "$WAN" ]; then
  [ "$VPN" != "$WAN" ] && ok "vpn exit differs from wan" "$VPN" || bad "VPN LEAK" "torrent traffic leaves on your own address"
else skip "vpn exit check" "could not read one of the addresses"; fi

sec "Monitoring tells the truth"
UP=$(on $PI 'sudo docker exec uptime-kuma sqlite3 /app/data/kuma.db "select count(*) from monitor where active=1"')
[ "${UP:-0}" -ge 15 ] && ok "monitors active" "$UP" || bad "monitors active" "only ${UP:-0}"
# A monitor named for a host that no longer exists is worse than no monitor.
STALE=$(on $PI 'sudo docker exec uptime-kuma sqlite3 /app/data/kuma.db "select count(*) from monitor where active=1 and (name like \"%pve01%\" or url like \"%86.140%\" or url like \"%50.111%\")"')
[ "${STALE:-0}" -eq 0 ] && ok "no monitors for dead hosts" || bad "stale monitors" "$STALE point at hosts that are gone"

sec "Runners"
for r in runner-233 pete-pi-1; do
  s=$(gh api orgs/PeteDio-Labs/actions/runners 2>/dev/null | python3 -c "
import sys,json
for x in json.load(sys.stdin).get('runners',[]):
    if x['name']=='$r': print(x['status'])" 2>/dev/null)
  [ "$s" = "online" ] && ok "$r" "online" || bad "$r" "${s:-not registered}"
done

printf "\n\033[1m%d passed, %d failed, %d skipped\033[0m\n" "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
