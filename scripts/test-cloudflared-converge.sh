#!/usr/bin/env bash
# Test for ansible/playbooks/files/cloudflared-converge.sh (PET-718). A fake `docker` and `wget` on
# PATH record each call. The test fails unless: the token reaches the env file and never the new
# command line or the output; the new connector starts before the old one stops; a connector that
# never reports ready leaves the old one running; a converged host changes nothing.
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
      *Config.Image*) cat "$T/image" ;;
      *json*)         cat "$T/cmd.json" ;;
      *range*)        cat "$T/cmd.lines" ;;
    esac ;;
esac
exit 0
D
cat > "$tmp/bin/wget" <<'D'
#!/bin/sh
[ "${READY:-1}" = 1 ] && echo '{"status":200,"readyConnections":4}'
exit 0
D
chmod +x "$tmp/bin/docker" "$tmp/bin/wget"
export T="$tmp" PATH="$tmp/bin:$PATH" READY_SLEEP=0 READY_TRIES=2
envfile="$tmp/etc/tunnel.env"
img=cloudflare/cloudflared:2026.10.4

old() {
  : > "$T/calls"; rm -rf "$T/etc"
  echo "$1" > "$T/image"
  printf '%s\n' tunnel --no-autoupdate --edge-ip-version 4 --protocol quic run --token SECRETTOKENVALUE > "$T/cmd.lines"
  echo '["tunnel","--no-autoupdate","--edge-ip-version","4","--protocol","quic","run","--token","SECRETTOKENVALUE"]' > "$T/cmd.json"
}
fail() { echo "FAIL: $*"; cat "$T/calls"; exit 1; }

# 1. happy path
old cloudflare/cloudflared:2026.10.4
out=$(sh "$script" "$img" cloudflared 192.168.50.112 20241 "$envfile")
grep -q 'SECRETTOKENVALUE' <<<"$out" && fail "token printed"
grep -q 'SECRETTOKENVALUE' "$T/calls" && fail "token on a docker command line"
[ "$(cat "$envfile")" = "TUNNEL_TOKEN=SECRETTOKENVALUE" ] || fail "env file wrong"
[ "$(stat -c %a "$envfile")" = 600 ] || fail "env file mode"
run=$(grep '^docker run' "$T/calls")
grep -q -- '--env-file' <<<"$run" || fail "no env-file"
grep -q -- '--metrics 0.0.0.0:20241' <<<"$run" || fail "no metrics flag"
grep -q -- '--edge-ip-version 4 --protocol quic' <<<"$run" || fail "old flags lost"
grep -q -- '--token' <<<"$run" && fail "token flag still passed"
run_at=$(grep -n '^docker run' "$T/calls" | cut -d: -f1)
stop_at=$(grep -n '^docker stop cloudflared$' "$T/calls" | cut -d: -f1)
[ "$run_at" -lt "$stop_at" ] || fail "old connector stopped before the new one ran"
grep -q '^docker rename cloudflared-new cloudflared$' "$T/calls" || fail "no final rename"

# 2. the new connector never reports ready
old "$img"
if READY=0 sh "$script" "$img" cloudflared 192.168.50.112 20241 "$envfile" >/dev/null 2>&1; then fail "not-ready run exited zero"; fi
grep -q '^docker stop cloudflared$' "$T/calls" && fail "old connector stopped despite no ready connection"
grep -q '^docker rm -f cloudflared-new$' "$T/calls" || fail "new connector not removed"

# 3. already converged
old "$img"
echo '["tunnel","--no-autoupdate","--metrics","0.0.0.0:20241","run"]' > "$T/cmd.json"
out=$(sh "$script" "$img" cloudflared 192.168.50.112 20241 "$envfile")
grep -q 'already converged' <<<"$out" || fail "did not detect convergence"
grep -q '^docker run' "$T/calls" && fail "ran a container on a converged host"

# 4. no token anywhere
old "$img"
: > "$T/cmd.lines"
if sh "$script" "$img" cloudflared 192.168.50.112 20241 "$envfile" >/dev/null 2>&1; then fail "ran without a token"; fi
echo "ok: token stays on the host, new connector runs first, no-ready keeps the old one, converged is a no-op"
