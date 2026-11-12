#!/usr/bin/env bash
# Test for ansible/playbooks/files/cloudflared-converge.sh (PET-718). A fake `docker` and `wget` on
# PATH record each call and model the two facts that broke earlier drafts: Docker refuses a second
# container on a published host port, and a stopped container keeps its image and command.
# The test fails unless:
#   - the token reaches the env file and never a command line or the output,
#   - the candidate runs, is ready, and only then does the old connector stop,
#   - an upgrade works while the old connector holds the stable port,
#   - a candidate that never gets ready leaves the old connector running,
#   - a final connector that never gets ready restores the old one,
#   - a converged and ready host changes nothing, and a stopped or unready one is not reported as converged,
#   - a missing token fails.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
script="$here/ansible/playbooks/files/cloudflared-converge.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
cat > "$tmp/bin/docker" <<'D'
#!/bin/sh
echo "docker $*" >> "$T/calls"
case "$1" in
  inspect)
    case "$3" in
      *Config.Image*)      cat "$T/image" ;;
      *State.Status*)      cat "$T/status" ;;
      *NetworkSettings*)   echo 172.17.0.9 ;;
      *json*)              cat "$T/cmd.json" ;;
      *range*)             cat "$T/cmd.lines" ;;
    esac ;;
  run)
    pub=""
    while [ $# -gt 0 ]; do [ "$1" = -p ] && pub=$2; shift; done
    if [ -n "$pub" ] && [ "$pub" = "$(cat "$T/held")" ]; then echo "port is already allocated" >&2; exit 125; fi
    [ -z "$pub" ] || echo "$pub" > "$T/final_pub" ;;
  stop) echo none > "$T/held"; echo exited > "$T/status" ;;
  start) echo running > "$T/status" ;;
esac
exit 0
D
cat > "$tmp/bin/wget" <<'D'
#!/bin/sh
case "$*" in
  *172.17.0.9*) [ "${READY_CAND:-1}" = 1 ] || exit 1 ;;
  *)            [ "${READY_FINAL:-1}" = 1 ] || exit 1 ;;
esac
echo '{"status":200,"readyConnections":4}'
D
chmod +x "$tmp/bin/docker" "$tmp/bin/wget"
export T="$tmp" PATH="$tmp/bin:$PATH" READY_SLEEP=0 READY_TRIES=2
envfile="$tmp/etc/tunnel.env"
img=cloudflare/cloudflared:2026.10.4
bind=192.168.50.112
run_script() { sh "$script" "$img" cloudflared "$bind" 20241 "$envfile"; }
fail() { echo "FAIL: $*"; cat "$T/calls"; exit 1; }
line() { grep -n "$1" "$T/calls" | head -1 | cut -d: -f1; }

# old <image> <status> <held-port> <token: yes|no>: the running connector as audit-cloudflared-112 found it.
old() {
  : > "$T/calls"; rm -rf "$T/etc" "$T/final_pub"
  echo "$1" > "$T/image"; echo "$2" > "$T/status"; echo "$3" > "$T/held"
  if [ "$4" = yes ]; then
    printf '%s\n' tunnel --no-autoupdate --edge-ip-version 4 --protocol quic run --token SECRETTOKENVALUE > "$T/cmd.lines"
    echo '["tunnel","--no-autoupdate","--edge-ip-version","4","--protocol","quic","run","--token","SECRETTOKENVALUE"]' > "$T/cmd.json"
  else
    : > "$T/cmd.lines"; echo '["tunnel"]' > "$T/cmd.json"
  fi
}
managed() { # a connector already on the managed configuration
  echo '["tunnel","--no-autoupdate","--metrics","0.0.0.0:20241","run"]' > "$T/cmd.json"
  mkdir -p "$T/etc"; echo "TUNNEL_TOKEN=x" > "$envfile"
}

# 1. first apply: the old connector publishes nothing.
old cloudflare/cloudflared:2026.10.4 running none yes
out=$(run_script)
grep -q 'SECRETTOKENVALUE' <<<"$out" && fail "token printed"
grep -q 'SECRETTOKENVALUE' "$T/calls" && fail "token on a docker command line"
[ "$(cat "$envfile")" = "TUNNEL_TOKEN=SECRETTOKENVALUE" ] || fail "env file wrong"
[ "$(stat -c %a "$envfile")" = 600 ] || fail "env file mode"
grep -- '^docker run' "$T/calls" | grep -q -- '--token' && fail "token flag still passed"
grep -- '^docker run' "$T/calls" | grep -q -- '--edge-ip-version 4 --protocol quic' || fail "old flags lost"
grep -- '^docker run.*--name cloudflared-new' "$T/calls" | grep -q -- ' -p ' && fail "candidate published a port"
[ "$(cat "$T/final_pub")" = "$bind:20241:20241" ] || fail "final connector missing the stable port"
[ "$(line 'docker run -d --name cloudflared-new')" -lt "$(line 'docker stop cloudflared$')" ] || fail "old stopped before the candidate ran"
[ "$(line 'docker stop cloudflared$')" -lt "$(line 'docker run -d --name cloudflared --restart')" ] || fail "final started before the old stopped"
grep -q '^docker rm -f cloudflared-new$' "$T/calls" || fail "candidate left running"

# 2. upgrade: the old connector already holds the stable port. A draft that published it on the candidate fails here.
old cloudflare/cloudflared:2026.9.0 running "$bind:20241:20241" yes
run_script >/dev/null || fail "upgrade failed while the old connector held the port"

# 3. the candidate never gets ready: the old connector must keep running.
old "$img" running none yes
if READY_CAND=0 run_script >/dev/null 2>&1; then fail "not-ready candidate exited zero"; fi
grep -q '^docker stop cloudflared$' "$T/calls" && fail "old connector stopped despite a not-ready candidate"
grep -q '^docker rm -f cloudflared-new$' "$T/calls" || fail "candidate not removed"

# 4. the final connector never gets ready: restore the old one.
old "$img" running none yes
if READY_FINAL=0 run_script >/dev/null 2>&1; then fail "not-ready final exited zero"; fi
grep -q '^docker rename cloudflared-prev cloudflared$' "$T/calls" || fail "old connector not restored"
grep -q '^docker start cloudflared$' "$T/calls" || fail "old connector not restarted"

# 5. converged, running and ready: change nothing.
old "$img" running none no; managed
out=$(run_script)
grep -q 'already converged' <<<"$out" || fail "did not detect convergence"
grep -q '^docker run' "$T/calls" && fail "ran a container on a converged host"

# 6. same configuration but stopped: start it, and say recovered, never converged.
old "$img" exited none no; managed
out=$(run_script)
grep -q 'recovered' <<<"$out" || fail "stopped connector not reported as recovered"
grep -q 'already converged' <<<"$out" && fail "a stopped connector reported as converged"
grep -q '^docker start cloudflared$' "$T/calls" || fail "stopped connector not started"

# 7. same configuration but not ready after the start: exit non-zero.
old "$img" exited none no; managed
if READY_FINAL=0 run_script >/dev/null 2>&1; then fail "a connector with no ready connection exited zero"; fi

# 8. no token anywhere.
old "$img" running none no
if run_script >/dev/null 2>&1; then fail "ran without a token"; fi
echo "ok: candidate first, upgrade past a held port, failed candidate or final keeps a connector, stopped is not converged"
