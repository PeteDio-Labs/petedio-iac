#!/usr/bin/env bash
# test-rotate-minio-221-root — run the on-host halves of rotate-minio-221-root.sh (REMOTE_ROTATE
# and REMOTE_RESTART) against a local fake of 221 (PET-797).
#
#   ./scripts/test-rotate-minio-221-root.sh
#
# Needs Linux userland: the remote text uses GNU `chown --reference` and `chmod --reference`,
# and the assertions use `sha256sum`. A stock Mac lacks them, so run this in a Linux shell or
# with GNU coreutils first in PATH. The preflight below exits 2 instead of reporting a rotation
# regression that is really a missing tool.
#
# Contacts nothing in the lab. It loads the shipped script with ROTATE_MINIO_SOURCE_ONLY=1, so
# the text under test is the real text. It then:
#   - runs that text with a PATH that has no curl, like Debian 13 on 221,
#   - points /etc/default/minio and the marker at a temp dir,
#   - answers /minio/health/ready from a local python3 server (or leaves the port closed),
#   - stubs systemctl, and shortens the 30 x 2 s poll to 3 x 0 s.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n       want %s, got %s\n' "$1" "$2" "$3"; }
eq()  { [ "$3" = "$2" ] && ok "$1" || bad "$1" "[$2]" "[$3]"; }

tmpf="$(mktemp)"
for need in "sha256sum" "chown --reference=$tmpf $tmpf" "chmod --reference=$tmpf $tmpf"; do
  # shellcheck disable=SC2086
  if ! $need </dev/null >/dev/null 2>&1; then
    rm -f "$tmpf"
    printf 'PREFLIGHT FAIL: `%s` does not run here. This test needs GNU coreutils (Linux).\n' "${need%% *}" >&2
    exit 2
  fi
done
rm -f "$tmpf"

export ROTATE_MINIO_SOURCE_ONLY=1
# shellcheck source=/dev/null
. "$HERE/rotate-minio-221-root.sh"
set +e +u
T="$(mktemp -d)"; SRV=""
trap '[ -n "$SRV" ] && kill "$SRV" 2>/dev/null; rm -rf "$T"' EXIT

PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
mkdir -p "$T/bin" "$T/www/minio/health"
echo ok > "$T/www/minio/health/ready"
# A PATH with the tools the remote text needs and no curl.
for tool in bash python3 seq sleep cat chown chmod mv rm sed dirname; do
  p="$(command -v "$tool")" && ln -s "$p" "$T/bin/$tool"
done
cat > "$T/bin/systemctl" <<'SH'
#!/bin/bash
echo "$*" >> "$FAKE_LOG"
[ "${FAKE_SYSTEMCTL_FAIL:-0}" = 1 ] && [ "$2" = minio ] && [ "$1" = restart ] && exit 1
exit 0
SH
chmod +x "$T/bin/systemctl"

# fake REMOTE-TEXT: swap the host paths, the port and the poll timing for local ones.
localize() {
  printf '%s' "$1" | sed \
    -e "s#/etc/default/minio#$T/minio.env#g" \
    -e "s#/root/.minio-rotation-pending#$T/pending#g" \
    -e "s#127.0.0.1:9000#127.0.0.1:$PORT#g" \
    -e 's#seq 1 30#seq 1 3#' -e 's#sleep 2#sleep 0#'
}
ROT="$(localize "$REMOTE_ROTATE")"
RST="$(localize "$REMOTE_RESTART")"

run() { # run SCRIPT: PATH has no curl; prints stdout, then "rc=N"
  /usr/bin/env -i PATH="$T/bin" FAKE_LOG="$T/log" FAKE_SYSTEMCTL_FAIL="${FAKE_SYSTEMCTL_FAIL:-0}" \
    "$T/bin/bash" -c "$1" > "$T/out" 2> "$T/err"
  echo $?
}
fresh() { printf 'MINIO_ROOT_USER=root\nMINIO_ROOT_PASSWORD=oldpw\nMINIO_VOLUMES=/data\n' > "$T/minio.env"; chmod 640 "$T/minio.env"; rm -f "$T/pending" "$T/log"; }

echo "the fake has no curl"
PATH="$T/bin" command -v curl >/dev/null; eq "curl absent from the test PATH" 1 $?
case "$REMOTE_ROTATE$REMOTE_RESTART" in *curl*) bad "no curl in either REMOTE_* text" none found ;; *) ok "no curl in either REMOTE_* text" ;; esac

echo "readiness answers (server up)"
python3 -m http.server "$PORT" --bind 127.0.0.1 -d "$T/www" >/dev/null 2>&1 & SRV=$!
for _ in $(seq 1 50); do (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null && break; sleep 0.1; done

fresh; rc="$(run "$ROT")"
eq "rotate: exits 0" 0 "$rc"
NEW="$(sed -n 's/^NEWPASS=//p' "$T/out")"
[ -n "$NEW" ] && ok "rotate: prints NEWPASS" || bad "rotate: prints NEWPASS" "non-empty" "empty"
eq "rotate: env file holds the new password" "MINIO_ROOT_PASSWORD=$NEW" "$(grep '^MINIO_ROOT_PASSWORD=' "$T/minio.env")"
eq "rotate: other lines kept" 2 "$(grep -c -E '^(MINIO_ROOT_USER=root|MINIO_VOLUMES=/data)$' "$T/minio.env")"
eq "rotate: mode kept" 640 "$(python3 -c "import os,sys;print(oct(os.stat(sys.argv[1]).st_mode&0o777)[2:])" "$T/minio.env")"
[ -e "$T/pending" ] && ok "rotate: pending marker left for the Mac to clear" || bad "rotate: pending marker" exists missing
eq "rotate: restarted minio once" 1 "$(grep -c '^restart minio' "$T/log")"
case "$(cat "$T/err")" in *"curl"*) bad "rotate: stderr free of curl errors" none "$(cat "$T/err")" ;; *) ok "rotate: stderr free of curl errors" ;; esac

fresh; rc="$(run "$RST")"
eq "restart: exits 0 and prints ready" "0 ready" "$rc $(cat "$T/out")"

echo "readiness never answers (server down) -> rollback"
kill "$SRV"; wait "$SRV" 2>/dev/null; SRV=""
fresh; rc="$(run "$ROT")"
eq "rotate: exits 1" 1 "$rc"
grep -q ROLLED_BACK "$T/err" && ok "rotate: stderr says ROLLED_BACK" || bad "rotate: stderr says ROLLED_BACK" yes "$(cat "$T/err")"
eq "rotate: old password restored" "MINIO_ROOT_PASSWORD=oldpw" "$(grep '^MINIO_ROOT_PASSWORD=' "$T/minio.env")"
eq "rotate: env file byte-identical" "$(printf 'MINIO_ROOT_USER=root\nMINIO_ROOT_PASSWORD=oldpw\nMINIO_VOLUMES=/data\n' | sha256sum | cut -c1-64)" "$(sha256sum < "$T/minio.env" | cut -c1-64)"
eq "rotate: mode kept" 640 "$(python3 -c "import os,sys;print(oct(os.stat(sys.argv[1]).st_mode&0o777)[2:])" "$T/minio.env")"
[ ! -e "$T/pending" ] && ok "rotate: pending marker removed" || bad "rotate: pending marker removed" gone present
eq "rotate: minio restarted again after rollback" 2 "$(grep -c '^restart minio' "$T/log")"
case "$(cat "$T/out")" in *NEWPASS*) bad "rotate: no NEWPASS on failure" none printed ;; *) ok "rotate: no NEWPASS on failure" ;; esac

fresh; rc="$(run "$RST")"
eq "restart: exits 1" 1 "$rc"

echo "systemctl restart fails -> rollback"
fresh; FAKE_SYSTEMCTL_FAIL=1 rc="$(FAKE_SYSTEMCTL_FAIL=1 run "$ROT")"
eq "rotate: exits 1" 1 "$rc"
eq "rotate: old password restored" "MINIO_ROOT_PASSWORD=oldpw" "$(grep '^MINIO_ROOT_PASSWORD=' "$T/minio.env")"
[ ! -e "$T/pending" ] && ok "rotate: pending marker removed" || bad "rotate: pending marker removed" gone present

echo "exit code 2 on bad usage"
"$HERE/rotate-minio-221-root.sh" --bogus >/dev/null 2>&1; eq "unknown flag" 2 $?

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
