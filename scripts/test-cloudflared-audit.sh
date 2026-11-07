#!/usr/bin/env bash
# Regression test for ansible/playbooks/files/cloudflared-audit.sh (PET-768). A fake `docker`
# on PATH returns secrets in the shapes the audit must hide: a long token, a short password, a
# value with an escaped quote, and `--token=<value>`. The test fails if any secret appears in the
# output, if a failed inspect exits zero, or if the summary line miscounts.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
script="$here/ansible/playbooks/files/cloudflared-audit.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
cat > "$tmp/bin/docker" <<'D'
#!/bin/sh
case "$1 $*" in
  "ps "*) echo aaa; echo bbb ;;
esac
[ "$1" = ps ] && exit 0
id=$(eval echo "\${$#}")
fmt=""
[ "$2" = "--format" ] && fmt=$3
if [ "${FAIL_ID:-}" = "$id" ]; then echo "inspect failed" >&2; exit 1; fi
case "$fmt" in
  CONTAINER*) echo "CONTAINER /cf-$id|image=cloudflare/cloudflared:2026.1.0|restart=always|network=host|state=running" ;;
  *Entrypoint*)
    [ "${FAIL_PART:-}" = args ] && { echo "inspect failed" >&2; exit 1; }
    # json output: a newline inside a value is the two characters \n, as Docker's json func emits it
    printf '%s\n' '"cloudflared"' '"tunnel"' '"--no-autoupdate"' '"run"' '"--token"' '"SHORTpw1"' '"--token=abc.def"' \
      '"eyJhIjoiTOKENVALUE"' '"--x=first\n-multiline-secret"' ;;
  *Env*)
    [ "${FAIL_PART:-}" = env ] && { echo "inspect failed" >&2; exit 1; }
    printf '%s\n' '"TUNNEL_TOKEN=eyJhIjoiTOKENVALUE"' '"PASSWORD=first\"tail"' '"MULTI=first\nshort-secret"' '"TZ=UTC"' ;;
esac
D
chmod +x "$tmp/bin/docker"

out=$(PATH="$tmp/bin:$PATH" sh "$script")
for secret in SHORTpw1 abc.def TOKENVALUE first tail short-secret multiline-secret; do
  if grep -q "$secret" <<<"$out"; then echo "FAIL: '$secret' leaked:"; echo "$out"; exit 1; fi
done
grep -q '^  ENV TUNNEL_TOKEN$' <<<"$out" || { echo "FAIL: env name missing"; exit 1; }
grep -q '^  ARG --token$' <<<"$out" || { echo "FAIL: flag name missing"; exit 1; }
grep -q '^AUDIT listed=2 inspected=2$' <<<"$out" || { echo "FAIL: summary wrong:"; echo "$out"; exit 1; }

if FAIL_ID=bbb PATH="$tmp/bin:$PATH" sh "$script" >/dev/null 2>&1; then
  echo "FAIL: a failed inspect exited zero"; exit 1
fi
for part in args env; do
  if FAIL_PART=$part PATH="$tmp/bin:$PATH" sh "$script" >/dev/null 2>&1; then
    echo "FAIL: a failed $part inspect exited zero"; exit 1
  fi
done
echo "ok: no secret leaked, partial read fails, summary counts match"
