#!/usr/bin/env bash
#
# seed-qbittorrent-vault.sh — write the Proton WireGuard credentials to
# kv/services/media/qbittorrent, prove the write by reading it back, and retire
# the stale kv/services/qbittorrent. PET-452.
#
# operator-run; requires VAULT_ADDR, VAULT_CACERT and a token from `vault login` or
# VAULT_TOKEN. No session runs it, and no value it handles is ever seen by one.
#
# WHY THIS SCRIPT EXISTS RATHER THAN THE RUNBOOK'S COMMAND.
#   docs/runbooks/qbittorrent-vault-secret.md tells you to run:
#
#     vault kv put kv/services/media/qbittorrent \
#       wireguard_private_key='...' wireguard_addresses='...'
#
#   That puts the key on a child process's argv, where any user on the box reads
#   it out of `ps` or /proc/<pid>/cmdline for as long as the process lives, and
#   where your shell history keeps it afterwards. PET-110 forbids exactly this,
#   and vault-seed.sh has honoured the rule since it was written. The runbook did
#   not. This script closes that gap for the one secret the runbook covers.
#
# HOW A VALUE TRAVELS HERE. From an env var or a silent `read -s` prompt, into a
# shell variable, NUL-separated over a PIPE to python3, which emits JSON PIPED to
# `vault kv put <path> -`. No argv, no temp file, no terminal echo, no disk. The
# read-back compares a SHA-256 digest rather than the value, so a mismatch is
# debuggable without printing a secret.
#
# WHERE THE VALUES COME FROM. The live key is in /opt/qbittorrent-vpn/.env on LXC
# 110, under PROTON_WG_PRIVATE_KEY and PROTON_WG_ADDRESSES. This script reads them
# as WIREGUARD_PRIVATE_KEY and WIREGUARD_ADDRESSES, the names gluetun receives them
# under in petedio-media-iac's docker-compose.yml.j2. Export them under those names,
# or let the script prompt. Git history holds no key: `git log --all -S
# WIREGUARD_PRIVATE_KEY` matches the template's variable name only.
#
# Usage:
#   export VAULT_ADDR="https://192.168.50.223:8200"
#   export VAULT_CACERT="$(pwd)/environments/homelab/vault-ca.crt"
#   vault login                       # or: export VAULT_TOKEN=<root token>
#   ./scripts/seed-qbittorrent-vault.sh              # prompts for both values
#   ./scripts/seed-qbittorrent-vault.sh --retire-old # also delete the stale path
#
# Optional pre-set env vars (skip the prompt for that value):
#   WIREGUARD_PRIVATE_KEY   WIREGUARD_ADDRESSES
#
# Idempotent. Re-running writes a new KV version holding the same values.
set -euo pipefail

NEW_PATH="kv/services/media/qbittorrent"
OLD_PATH="kv/services/qbittorrent"
RETIRE_OLD=0

while [ $# -gt 0 ]; do
  case "$1" in
    --retire-old) RETIRE_OLD=1 ;;
    -h|--help) sed -n '2,44p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "FATAL: unknown argument: $1  (try --help)" >&2; exit 1 ;;
  esac
  shift
done

# --- preflight -------------------------------------------------------------------
: "${VAULT_ADDR:?set VAULT_ADDR (e.g. https://192.168.50.223:8200)}"
: "${VAULT_CACERT:?set VAULT_CACERT to the path of environments/homelab/vault-ca.crt}"

command -v vault   >/dev/null 2>&1 || { echo "FATAL: vault CLI not found on PATH" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found on PATH (needed to build JSON payloads)" >&2; exit 1; }

# Vault seals nightly. Fail here rather than half-way through.
if ! vault status >/dev/null 2>&1; then
  echo "FATAL: 'vault status' failed — Vault unreachable or sealed. Check VAULT_ADDR/CACERT and unseal." >&2
  exit 1
fi

# Ask the CLI for the token, not VAULT_TOKEN. `vault login` stores its token with the
# token helper and exports nothing, so a check of the variable refused that route
# (PET-452). The CLI reads VAULT_TOKEN first and the helper second.
if ! vault token lookup >/dev/null 2>&1; then
  echo "FATAL: no usable Vault token. Run 'vault login', or export VAULT_TOKEN (root token)." >&2
  exit 1
fi

# --- helper: load a value from env var $1, else prompt silently --------------------
# Sets global REPLY_VALUE. Never echoes the value. Rejects empty input. Copied in
# shape from vault-seed.sh so both scripts read the same way.
load_value() {
  local var_name="$1" prompt="$2" existing
  existing="${!var_name-}"
  if [ -n "$existing" ]; then
    REPLY_VALUE="$existing"
    echo "  $var_name: using exported env var"
    return 0
  fi
  local v=""
  while [ -z "$v" ]; do
    read -r -s -p "  $prompt: " v < /dev/tty
    echo >&2
    [ -z "$v" ] && echo "  (empty — please re-enter)" >&2
  done
  REPLY_VALUE="$v"
}

# --- helper: SHA-256 of a value, via stdin so it never reaches an argv ------------
digest() { printf '%s' "$1" | shasum -a 256 | cut -c1-12; }

echo "Seeding ${NEW_PATH} at ${VAULT_ADDR} ..."
echo "(values are read from env or prompted silently; nothing is echoed or written to disk)"
echo

# --- collect ---------------------------------------------------------------------
load_value WIREGUARD_PRIVATE_KEY "Proton WireGuard private key (PROTON_WG_PRIVATE_KEY in /opt/qbittorrent-vpn/.env on LXC 110)"
wg_key="${REPLY_VALUE}"
load_value WIREGUARD_ADDRESSES   "Proton WireGuard addresses (PROTON_WG_ADDRESSES in the same .env, e.g. 10.2.0.2/32)"
wg_addr="${REPLY_VALUE}"

# Shape checks, not value checks. A WireGuard private key is 32 bytes base64, so 44
# characters ending in '='. Catching a truncated paste here is worth more than the
# check costs, because the failure it prevents is a VPN that comes up and routes
# nothing — the silent kind this lab keeps paying for.
if ! printf '%s' "$wg_key" | grep -Eq '^[A-Za-z0-9+/]{43}=$'; then
  echo "FATAL: the private key is not 44 characters of base64 ending in '='." >&2
  echo "       Length read: ${#wg_key}. The value itself is not printed." >&2
  exit 1
fi
if ! printf '%s' "$wg_addr" | grep -Eq '^[0-9a-fA-F:./,[:space:]]+$'; then
  echo "FATAL: the addresses field holds characters no CIDR list contains." >&2
  exit 1
fi
echo "  shape: private key 44 chars base64; addresses ${#wg_addr} chars"
echo

# --- write -----------------------------------------------------------------------
# PET-110: the pairs travel NUL-separated over a pipe to python3, which emits a
# JSON object piped to `vault kv put <path> -`. Vault reads the payload from stdin.
# This is the same route vault-seed.sh's put_entry takes, and the reason neither
# script can leak through `ps`.
json="$(printf '%s\0' \
  "wireguard_private_key=${wg_key}" \
  "wireguard_addresses=${wg_addr}" | python3 -c '
import json, sys
d = {}
for pair in sys.stdin.buffer.read().split(b"\0"):
    if not pair:
        continue
    k, sep, v = pair.decode().partition("=")
    if not sep:
        sys.exit(f"FATAL: malformed pair for key {k!r} (no =)")
    d[k] = v
print(json.dumps(d))
')"

if printf '%s' "$json" | vault kv put "$NEW_PATH" - >/dev/null; then
  echo "  -> wrote ${NEW_PATH}"
else
  echo "FATAL: failed to write ${NEW_PATH}" >&2
  exit 1
fi
unset json

# --- read back -------------------------------------------------------------------
# A write that reports success and stored something else is the failure this whole
# item exists to rule out, so read the path back and compare. The comparison is on
# digests: a mismatch is debuggable and a match prints no secret.
echo
echo "Reading ${NEW_PATH} back ..."
readback="$(vault kv get -format=json "$NEW_PATH")" || {
  echo "FATAL: the write reported success and the path does not read back." >&2
  exit 1
}

fields_ok=1
for f in wireguard_private_key wireguard_addresses; do
  case "$f" in
    wireguard_private_key) expect="$wg_key" ;;
    wireguard_addresses)   expect="$wg_addr" ;;
  esac
  got="$(printf '%s\0%s' "$f" "$readback" | python3 -c '
import json, sys
field, blob = sys.stdin.buffer.read().split(b"\0", 1)
data = json.loads(blob).get("data", {}).get("data", {})
sys.stdout.write(data.get(field.decode(), ""))
')"
  if [ -z "$got" ]; then
    echo "  ✗ ${f}: absent from the read-back"
    fields_ok=0
  elif [ "$(digest "$got")" = "$(digest "$expect")" ]; then
    echo "  ✓ ${f}: matches what was sent (sha256 $(digest "$expect")…)"
  else
    echo "  ✗ ${f}: stored value differs — sent $(digest "$expect")… stored $(digest "$got")…"
    fields_ok=0
  fi
  unset got
done
unset expect

version="$(printf '%s' "$readback" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["metadata"]["version"])')"
echo "  version: ${version}"
unset readback wg_key wg_addr

if [ "$fields_ok" -ne 1 ]; then
  echo >&2
  echo "FATAL: the read-back did not match. ${OLD_PATH} was left alone." >&2
  exit 1
fi

# --- retire the old path ---------------------------------------------------------
# kv/services/qbittorrent has held `username` and `password` since 2026-06-03. The
# runbook records that pair as a phantom: qBittorrent's WebUI password is set in
# its own config, nothing reads these two, and seeding them was the mistake this
# item closes. Deleting metadata destroys every version, so it needs the flag and
# an answer, and it runs only after the new path verified above.
echo
if [ "$RETIRE_OLD" -ne 1 ]; then
  echo "${OLD_PATH} was left in place. Re-run with --retire-old to delete it."
  exit 0
fi

if ! old="$(vault kv get -format=json "$OLD_PATH" 2>/dev/null)"; then
  echo "${OLD_PATH}: already absent, nothing to retire."
  exit 0
fi
echo "${OLD_PATH} holds these field names (values are not read):"
printf '%s' "$old" | python3 -c '
import json, sys
for k in json.load(sys.stdin)["data"]["data"]:
    print(f"  - {k}")
'
unset old
printf 'Delete every version of %s? [y/N]: ' "$OLD_PATH"
# `|| answer=""` matters: under `set -e` a read that reaches EOF — no tty, or the
# script driven from a pipe — aborts here with no message and no exit code worth
# reading, which looks identical to a refusal and is not one. Treat EOF as "no",
# out loud.
answer=""
read -r answer < /dev/tty || answer=""
case "$answer" in
  y|Y|yes|YES) ;;
  "") echo; echo "  no answer read (not a terminal?) — ${OLD_PATH} left in place."; exit 0 ;;
  *) echo "  left in place."; exit 0 ;;
esac

if vault kv metadata delete "$OLD_PATH" >/dev/null; then
  if vault kv get "$OLD_PATH" >/dev/null 2>&1; then
    echo "  ✗ the delete reported success and the path still reads. Check the token's policy." >&2
    exit 1
  fi
  echo "  ✓ ${OLD_PATH} deleted and confirmed absent"
else
  echo "FATAL: failed to delete ${OLD_PATH}" >&2
  exit 1
fi

echo
echo "Done. Next: ./scripts/vault-verify.sh"
