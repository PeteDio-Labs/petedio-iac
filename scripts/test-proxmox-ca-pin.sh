#!/usr/bin/env bash
# test-proxmox-ca-pin — prove the two Proxmox scripts pin a CA and fail closed (PET-541).
#
# `curl` is a shim that records its arguments and answers a canned permissions or config
# document. The assertions read the record: every token-bearing call carries --cacert and
# none carries -k or --insecure, and a missing CA file stops the script before any call.
#
#   ./scripts/test-proxmox-ca-pin.sh
#
# Contacts nothing. No token, no network. Needs bash and python3.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

mkdir "$TMP/bin"
cat >"$TMP/bin/curl" <<'SH'
#!/usr/bin/env bash
echo "$*" >>"$CURL_LOG"
echo '{"data":{"/":{"Pool.Allocate":1,"Pool.Audit":1}}}'
SH
chmod +x "$TMP/bin/curl"
printf 'stub ca\n' >"$TMP/ca.crt"
export PATH="$TMP/bin:$PATH" CURL_LOG="$TMP/curl.log"
export PROXMOX_API_TOKEN='stub@pam!t=secret' PROXMOX_RO_TOKEN='stub@pam!t=secret'

run() { : >"$CURL_LOG"; "$@" >"$TMP/out" 2>&1; }

run env PROXMOX_CA_FILE="$TMP/ca.crt" "$HERE/proxmox-preflight-perms.sh" --require Pool.Allocate
if [ -s "$CURL_LOG" ] && grep -q -- "--cacert $TMP/ca.crt" "$CURL_LOG" && ! grep -qE -- ' -[a-zA-Z]*k|--insecure' "$CURL_LOG"; then
  ok "preflight pins the CA and never sends -k"; else bad "preflight pin"; fi

run env PROXMOX_CA_FILE="$TMP/missing.crt" "$HERE/proxmox-preflight-perms.sh" --require Pool.Allocate
rc=$?
if [ "$rc" != 0 ] && [ ! -s "$CURL_LOG" ]; then ok "preflight fails closed with no CA"; else bad "preflight fail-closed (rc=$rc)"; fi

run env PROXMOX_CA_FILE="$TMP/ca.crt" "$HERE/proxmox-ro-config.sh" pve02 106
if [ -s "$CURL_LOG" ] && grep -q -- "--cacert $TMP/ca.crt" "$CURL_LOG" && ! grep -qE -- ' -[a-zA-Z]*k|--insecure' "$CURL_LOG"; then
  ok "ro-config pins the CA and never sends -k"; else bad "ro-config pin"; fi

run env PROXMOX_CA_FILE="$TMP/missing.crt" "$HERE/proxmox-ro-config.sh" pve02 106
rc=$?
if [ "$rc" != 0 ] && [ ! -s "$CURL_LOG" ]; then ok "ro-config fails closed with no CA"; else bad "ro-config fail-closed (rc=$rc)"; fi

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
