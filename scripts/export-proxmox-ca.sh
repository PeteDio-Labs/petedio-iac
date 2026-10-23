#!/usr/bin/env bash
# export-proxmox-ca.sh — write the Proxmox cluster CA (a public certificate) to
# environments/homelab/proxmox-ca.crt, so scripts/proxmox-preflight-perms.sh and
# scripts/proxmox-ro-config.sh pin it with --cacert instead of curl -k (PET-541).
#
# Reads the ca_pem field of Vault kv/services/claude-247-pve. Needs a token that reads it
# (VAULT_TOKEN, or `vault login`). Prints only the certificate's subject, expiry and SANs.
# The script writes no secret: the CA is public. Commit the file in a PR it prints the path of.
#
# Usage: scripts/export-proxmox-ca.sh [--check <ip>...]
#   --check   also dial each address on :8006 with the new CA and report the verify result
#             (default: 192.168.50.10 and 192.168.50.11, the two nodes the scripts dial).
set -euo pipefail

die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${PROXMOX_CA_FILE:-$SCRIPT_DIR/../environments/homelab/proxmox-ca.crt}"
HOSTS=(192.168.50.10 192.168.50.11)
if [ "${1:-}" = "--check" ]; then shift; [ $# -gt 0 ] && HOSTS=("$@"); fi

for t in vault openssl; do command -v "$t" >/dev/null || die "$t not in PATH."; done
export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$SCRIPT_DIR/../environments/homelab/vault-ca.crt}"

pem="$(vault kv get -field=ca_pem kv/services/claude-247-pve 2>/dev/null)" ||
  die "could not read ca_pem from kv/services/claude-247-pve (token set? Vault unsealed?)."
[ -n "$pem" ] || die "ca_pem is empty."

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
printf '%s\n' "$pem" >"$tmp"
openssl x509 -in "$tmp" -noout -subject -enddate >/dev/null 2>&1 || die "ca_pem is not a valid certificate."
openssl x509 -in "$tmp" -noout -subject -enddate

install -m 0644 "$tmp" "$OUT"
printf 'wrote %s\n' "$OUT"

fail=0
for h in "${HOSTS[@]}"; do
  res="$(openssl s_client -connect "$h:8006" -CAfile "$OUT" -verify_return_error -verify_ip "$h" </dev/null 2>&1 |
    sed -n 's/^ *Verification: *//p;s/^Verify return code: *//p' | head -1)"
  printf '  %s:8006 -> %s\n' "$h" "${res:-no answer}"
  case "$res" in OK* | "0 (ok)") ;; *) fail=1 ;; esac
done
[ "$fail" = 0 ] || die "a node's certificate does not verify against this CA for its IP. Do not merge the file until the SANs cover the address the scripts dial."
