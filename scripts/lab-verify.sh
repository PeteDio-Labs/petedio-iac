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

# Find whichever node actually holds a guest, and exec inside it there.
#
# ⚠ NEVER hardcode the node in a check. Guests move: the platform tier left pve02
# for pve03 on 2026-09-04 (PET-334), and the arr stack moved the day before. A
# check pinned to a node does not report "moved" -- it reports the SERVICE as
# broken, because `pct exec` on the wrong host simply fails. That is how a healthy
# Postgres was reported as "not accepting" minutes after it migrated.
#
# pve03 is reached as an unprivileged user, so pct needs sudo there and does not
# on pve02. That asymmetry is the other reason to funnel every exec through here.
node_for() {
  on $PVE02 "pct config $1 >/dev/null 2>&1" && { echo "$PVE02"; return; }
  on $PVE03 "sudo /usr/sbin/pct config $1 >/dev/null 2>&1" && { echo "$PVE03"; return; }
  echo ""
}
pct_on() {  # node, vmid, command
  if [ "$1" = "$PVE03" ]; then on "$1" "sudo /usr/sbin/pct exec $2 -- $3"
  else on "$1" "pct exec $2 -- $3"; fi
}

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

# ── Placement (PET-334) ───────────────────────────────────────────────────────
# pve02 is the MEDIA node: it holds the disks, Plex and qBittorrent, and nothing
# else. Everything platform-tier lives on pve03, which has twice the cores and
# ten times the free space, and — the actual reason — is not the node carrying
# the fragile USB storage.
#
# This is asserted rather than assumed because a guest can move without anyone
# deciding it should: an HA failover, a half-finished migration, or a `pct
# migrate` typed against the wrong node. Nothing else here would notice. The
# services would all still answer, from the wrong machine, until pve02 lost a
# USB enclosure and took the platform down with it.
#
# ⚠ Terraform cannot hold this line for you. `node_name` and `datastore_id` both
# force REPLACEMENT on the bpg provider, so a config edit destroys and rebuilds
# the container rather than moving it. Placement is changed with `pct migrate`
# and then reconciled into state — see docs/runbooks/pve03-platform-move.md.
sec "Placement matches intent"
INTENT_PVE02="110 236"
PLACEMENT=$(on $PVE02 'pvesh get /cluster/resources --type vm --output-format json' 2>/dev/null)
if [ -z "$PLACEMENT" ]; then
  bad "placement readable" "could not read /cluster/resources"
else
  # ⚠ Assign the command substitution to a variable, THEN eval it. Writing
  # `eval "$(python3 <<'"'"'PYEOF'"'"' ...)"` looks equivalent and is not: inside the
  # outer double quotes bash stops honouring the quoted heredoc delimiter, the
  # body is expanded, and the python arrives mangled. It still RUNS -- it printed
  # `101('"'"''"'"')` where the guest name belonged -- so the check reports garbage
  # rather than failing. Found writing this check (PET-334).
  _placement_eval=$(PLACEMENT="$PLACEMENT" WANT02="$INTENT_PVE02" python3 <<'PYEOF'
import json, os
want02 = set(os.environ["WANT02"].split())
rows = json.loads(os.environ["PLACEMENT"])
wrong = []
for r in rows:
    vmid = str(r.get("vmid") or "")
    if not vmid: continue
    node = r.get("node") or ""
    expect = "pve02" if vmid in want02 else "pve03"
    if node != expect:
        wrong.append(f"{vmid}({r.get('name','')}) on {node}, want {expect}")
print("WRONG=%s" % json.dumps(";".join(wrong)))
print("NGUESTS=%d" % len(rows))
PYEOF
)
  eval "$_placement_eval"
  if [ -z "$WRONG" ]; then
    ok "every guest on its intended node" "$NGUESTS guests; only 110+236 on pve02"
  else
    IFS=';' read -ra W <<< "$WRONG"
    for w in "${W[@]}"; do bad "misplaced guest" "$w"; done
  fi
fi

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
PGNODE=$(node_for 231)
if [ -z "$PGNODE" ]; then bad "postgres" "guest 231 not found on any node"; else
  PG=$(pct_on "$PGNODE" 231 "pg_isready" | grep -c accepting)
  [ "${PG:-0}" -ge 1 ] && ok "postgres" "accepting connections on $PGNODE" \
    || bad "postgres" "not accepting on $PGNODE"
fi
# Vault speaks HTTPS. The same path over http returns a bare 400 that reads as a
# broken server and is not.
SEAL=$(on $PVE02 "curl -sk -m 8 https://192.168.50.223:8200/v1/sys/seal-status | grep -o '\"sealed\":[a-z]*'")
[ "$SEAL" = '"sealed":false' ] && ok "vault unsealed" || bad "vault" "${SEAL:-unreachable}"

sec "The media pipeline, end to end"
# A root folder the app cannot see is the difference between a library and a
# directory listing.
#
# The arr apps live on pve03 since 2026-09-04, so look for each guest on whichever
# node actually holds it. Hard-coding the node makes this SKIP after a migration,
# and a check that skips silently is worse than one that fails.
for e in "104|sonarr|192.168.50.15:8989|/var/lib/sonarr/config.xml" "105|radarr|192.168.50.16:7878|/var/lib/radarr/config.xml"; do
  IFS='|' read -r id nm addr cfg <<< "$e"
  hostnode=$(node_for "$id")
  [ -z "$hostnode" ] && { bad "$nm" "not found on any node"; continue; }
  k=$(pct_on "$hostnode" "$id" "cat $cfg" | grep -o '<ApiKey>[^<]*' | cut -c9-)
  [ -z "$k" ] && { skip "$nm root folders" "no api key"; continue; }
  n=$(on "$hostnode" "curl -s -m 10 -H 'X-Api-Key: $k' http://$addr/api/v3/rootfolder | grep -c '\"accessible\": *true'")
  [ "${n:-0}" -ge 1 ] && ok "$nm root folders" "$n accessible on $hostnode" || bad "$nm root folders" "none accessible"
  h=$(on "$hostnode" "curl -s -m 10 -H 'X-Api-Key: $k' http://$addr/api/v3/health | grep -c '\"type\":\"error\"'")
  [ "${h:-0}" -eq 0 ] && ok "$nm health" "no errors" || bad "$nm health" "$h error-level issues"
done
# The library itself, per guest, at whatever path that guest actually mounts it.
#
# WHY THIS EXISTS. sonarr/radarr/prowlarr moved to pve03 on 2026-09-04 and pve03
# has NO ZFS -- `media` and `downloads` are pve02's pools reached over NFS. The
# library became a network dependency for the apps that import into it, and
# nothing here noticed. PET-322 exists because these mounts do go missing.
#
# A failed mount leaves an EMPTY DIRECTORY behind, which reads as a library with
# nothing in it rather than as an error. So: mounted, then non-empty, then
# actually written to.
#
# ⚠ NEVER HARDCODE THE IN-CONTAINER PATH. It differs per guest, and assuming it
# is how this check first went wrong (PET-333):
#     104 sonarr    /mnt/media   /downloads
#     109 prowlarr  /media       /downloads
#     236 plex-gpu  /mnt/media   /mnt/downloads (ro)
# In 104, `/mnt/downloads` is a stray empty directory on the 4 G rootfs -- writable,
# and nothing to do with the pool. A check that touched it would pass while proving
# the opposite of what it claims. The path is read from `pct config`'s mp= field.
#
# ⚠ AND TEST FROM INSIDE THE CONTAINER, never from the host account. The paths are
# owned by the unprivileged-LXC mapped ids with no o+w (media 100000:100999,
# downloads 101000:100000), so an operator's own uid is CORRECTLY refused.
#
# The group assertion is `file inherits directory`, not a literal: media and
# downloads have different groups, so either constant would be wrong for the other.
pct_config() {  # node, vmid
  if [ "$1" = "$PVE03" ]; then on "$1" "sudo /usr/sbin/pct config $2"
  else on "$1" "pct config $2"; fi
}
for e in "104|sonarr" "105|radarr" "109|prowlarr" "110|qbittorrent" "236|plex-gpu"; do
  IFS='|' read -r id nm <<< "$e"
  hostnode=$(node_for "$id")
  [ -z "$hostnode" ] && { bad "$nm library" "guest not found on any node"; continue; }
  cfg=$(pct_config "$hostnode" "$id" | grep -E '^mp[0-9]+:')
  [ -z "$cfg" ] && { skip "$nm library" "declares no mount points"; continue; }
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    d=$(sed -n 's/.*,mp=\([^,]*\).*/\1/p' <<< "$line")
    [ -z "$d" ] && continue
    ro=0; grep -q ',ro=1' <<< "$line" && ro=1
    label="$nm $d"
    if ! pct_on "$hostnode" "$id" "mountpoint -q $d"; then
      bad "$label" "not mounted -- the app sees an empty directory"; continue
    fi
    n=$(pct_on "$hostnode" "$id" "ls -A $d" | wc -l | tr -d ' ')
    if [ "${n:-0}" -eq 0 ]; then
      bad "$label" "mounted but EMPTY -- export gone, or mounted over"; continue
    fi
    read -r fg dg <<< "$(pct_on "$hostnode" "$id" \
      "sh -c 'T=$d/.lab-verify.\$\$; touch \$T 2>/dev/null || exit 1; stat -c %g \$T; stat -c %g $d; rm -f \$T'" | tr '\n' ' ')"
    if [ "$ro" = "1" ]; then
      # Declared ro=1. Writable here would mean the flag is not in force.
      [ -z "$fg" ] && ok "$label" "$n entries, read-only as declared, on $hostnode" \
                   || bad "$label" "declared ro=1 but IS WRITABLE"
    elif [ -z "$fg" ]; then
      bad "$label" "$n entries, NOT writable -- imports will fail"
    elif [ "$fg" != "$dg" ]; then
      bad "$label" "writable but setgid lost (file $fg, dir $dg) -- other apps will not read it"
    else
      ok "$label" "$n entries, writable, setgid ($fg) on $hostnode"
    fi
  done <<< "$cfg"
done

# The kill switch is only real if qbit has no network of its own.
QBNODE=$(node_for 110)
NS=$(pct_on "${QBNODE:-$PVE02}" 110 "docker inspect qbittorrent --format '{{.HostConfig.NetworkMode}}'" 2>/dev/null)
case "$NS" in container:*) ok "qbit inside gluetun netns" "no path out if the tunnel drops";; *) bad "qbit netns" "got '${NS:-unknown}' — traffic may bypass the VPN";; esac
VPN=$(pct_on "${QBNODE:-$PVE02}" 110 "docker exec gluetun wget -qO- -T 10 https://api.ipify.org" 2>/dev/null)
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
