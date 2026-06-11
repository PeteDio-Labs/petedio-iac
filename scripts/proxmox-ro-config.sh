#!/usr/bin/env bash
# proxmox-ro-config.sh — read-only dump of a Proxmox guest's LIVE config, so the
# autonomous loop can author a brownfield capture (terraform import) that plans as a
# NO-OP without guessing specs (cores/mem/rootfs/mounts/template/...).
#
# READ-ONLY by construction: authenticates with the PVEAuditor token
# (petedio@pam!loop-ro) and only ever issues a GET. It cannot create, modify, or
# destroy anything. Mutation (terraform apply/import, state edits, SSH-to-configure)
# stays forbidden for the loop — see docs/runbooks/loop-proxmox-readonly.md and the
# Linear "Agent Loop Operations" doc.
#
# Usage:
#   scripts/proxmox-ro-config.sh <node> <vmid> [lxc|qemu]
#     <node>   pve01 | pve02      (mapped to its endpoint; or set PROXMOX_RO_ENDPOINT)
#     <vmid>   e.g. 106
#     [kind]   lxc (default) | qemu
#
# Token resolution (first set wins; the token is NEVER printed):
#   $PROXMOX_RO_TOKEN                          full 'user@realm!tokenid=secret'
#   else Vault kv/services/agent-loop          field proxmox_ro_token
#
# Endpoint: $PROXMOX_RO_ENDPOINT (e.g. https://192.168.50.10:8006), else node->IP below.
set -euo pipefail

die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ $# -ge 2 ] || die "usage: $(basename "$0") <node> <vmid> [lxc|qemu]"
NODE="$1"
VMID="$2"
KIND="${3:-lxc}"
case "$KIND" in
  lxc | qemu) ;;
  *) die "kind must be lxc or qemu (got '$KIND')" ;;
esac

for t in curl python3; do command -v "$t" >/dev/null || die "$t not in PATH."; done

# --- endpoint (pve01 = .10, pve02 = .11; cluster nodes differ — see docs/GOTCHAS.md) ---
declare -A NODE_IP=([pve01]=192.168.50.10 [pve02]=192.168.50.11)
if [ -n "${PROXMOX_RO_ENDPOINT:-}" ]; then
  ENDPOINT="${PROXMOX_RO_ENDPOINT%/}"
else
  ip="${NODE_IP[$NODE]:-}"
  [ -n "$ip" ] || die "unknown node '$NODE' (known: ${!NODE_IP[*]}); or set PROXMOX_RO_ENDPOINT."
  ENDPOINT="https://${ip}:8006"
fi

# --- token (never printed) ---
TOKEN="${PROXMOX_RO_TOKEN:-}"
if [ -z "$TOKEN" ]; then
  command -v vault >/dev/null || die "PROXMOX_RO_TOKEN unset and vault not in PATH."
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
  export VAULT_CACERT="${VAULT_CACERT:-$SCRIPT_DIR/../environments/homelab/vault-ca.crt}"
  TOKEN="$(vault kv get -field=proxmox_ro_token kv/services/agent-loop 2>/dev/null)" ||
    die "could not read proxmox_ro_token from kv/services/agent-loop (token seeded? VAULT_TOKEN set?)."
fi
[ -n "$TOKEN" ] || die "empty Proxmox RO token."

# --- read-only GET (insecure: self-signed homelab cert, matches provider insecure=true) ---
url="${ENDPOINT}/api2/json/nodes/${NODE}/${KIND}/${VMID}/config"
resp="$(curl -fsSk -H "Authorization: PVEAPIToken=${TOKEN}" "$url")" ||
  die "GET ${url} failed (token valid? PVEAuditor ACL granted? node reachable?)."

# Pretty-print the .data config map (python3 — jq isn't on the loop host).
printf '%s' "$resp" | python3 -c \
  'import json,sys; print(json.dumps(json.load(sys.stdin).get("data", {}), indent=2, sort_keys=True))'
