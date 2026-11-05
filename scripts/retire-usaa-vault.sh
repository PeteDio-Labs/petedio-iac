#!/usr/bin/env bash
# retire-usaa-vault.sh — delete the USAA tracker's Vault secrets after it is torn down (PET-590).
#
# RUN IT AFTER petedio-iac#600 has applied. That apply removes the usaa database entry whose
# ephemeral read of kv/db/usaa would otherwise fail, and destroys LXC 238, the only consumer.
# The script reads the cluster config over SSH and stops unless CT 238 is gone.
#
# WHAT IT DELETES (permanently, with every version): `vault kv metadata delete`.
#   kv/db/usaa            the app's database password
#   kv/services/usaa      bearer tokens, calendar address, deploy key, notify token
# WHAT IT KEEPS BY DEFAULT
#   kv/services/usaa-minio   the scoped key for the usaa-statements bucket, which was kept
#                            because it holds the only copy of the statements. Pass
#                            --with-minio once Pedro has exported or removed the bucket.
#
# It prints paths and never a value. Vault token: $VAULT_TOKEN, else the macOS Keychain
# item $VAULT_TOKEN_KEYCHAIN_ITEM. Run only on Pedro's word.
#
# Usage:
#   ./scripts/retire-usaa-vault.sh             # dry run: reports found or absent per path
#   ./scripts/retire-usaa-vault.sh --apply     # deletes, then verifies each path is gone
#   ./scripts/retire-usaa-vault.sh --apply --with-minio
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$REPO_ROOT/environments/homelab/vault-ca.crt}"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"

APPLY=0; WITH_MINIO=0
for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    --with-minio) WITH_MINIO=1 ;;
    *) echo "unknown argument: $a" >&2; exit 2 ;;
  esac
done

if [ -z "${VAULT_TOKEN:-}" ]; then
  VAULT_TOKEN="$(security find-generic-password -s "$VAULT_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null || true)"
  export VAULT_TOKEN
fi
[ -n "${VAULT_TOKEN:-}" ] || { echo "FAIL: no Vault token (set VAULT_TOKEN or the Keychain item)" >&2; exit 1; }

PATHS=(kv/db/usaa kv/services/usaa)
[ "$WITH_MINIO" = 1 ] && PATHS+=(kv/services/usaa-minio)

# Guard: Proxmox itself must say CT 238 no longer exists. An unanswered ping proves nothing
# (a stopped container, a dropped reply and a failed ping all look alike), so this reads the
# cluster config over SSH and demands the literal answer GONE. Any other result, including an
# SSH failure, stops the script before it deletes anything.
# The default is pve02 (192.168.50.11). It accepts the operator's default SSH key, which
# 192.168.50.10 (pve03) refuses. Every node reads the same /etc/pve, so any reachable node
# answers the question. Set PVE_HOST to use another node.
PVE_HOST="${PVE_HOST:-root@192.168.50.11}"
# The remote script lists every node's lxc/ and qemu-server/ directory. `set -e` makes any
# listing error end it without printing GONE, so a permission or I/O error is never read as
# absence. It prints PRESENT when a 238 config exists and GONE only after every listing worked.
REMOTE='set -e
[ -d /etc/pve/nodes ]
n=0
for d in /etc/pve/nodes/*/; do
  for kind in lxc qemu-server; do
    list="$(ls "${d}${kind}")"
    case " $(echo $list) " in *" 238.conf "*) echo PRESENT; exit 0 ;; esac
  done
  n=$((n+1))
done
[ "$n" -ge 1 ]
echo GONE'
if ! guard="$(printf '%s\n' "$REMOTE" | ssh -o BatchMode=yes -o ConnectTimeout=10 "$PVE_HOST" bash -s 2>/dev/null)"; then
  guard="unreadable"
fi
if [ "$guard" != "GONE" ]; then
  echo "FAIL: could not confirm CT 238 is gone from the cluster (got: ${guard:-nothing}). Apply petedio-iac#600 first, or set PVE_HOST to a node you can reach." >&2
  exit 1
fi
echo "ok: no CT 238 config on any node ($PVE_HOST)"

# kv_state PATH -> prints "found" or "absent"; exits non-zero on any other outcome (sealed
# Vault, expired token, transport error). Only Vault's own "No value found" counts as absent.
kv_state() {
  local out rc=0
  out="$(vault kv metadata get -format=json "$1" 2>&1)" || rc=$?
  if [ "$rc" = 0 ]; then
    printf '%s' "$out" | python3 -c 'import json,sys; json.load(sys.stdin)["data"]["versions"]' >/dev/null || return 1
    echo found
  elif printf '%s' "$out" | grep -q "No value found"; then
    echo absent
  else
    echo "FAIL: cannot read metadata for $1: $out" >&2
    return 1
  fi
}

fail=0
for p in "${PATHS[@]}"; do
  state="$(kv_state "$p")" || { fail=1; continue; }
  if [ "$state" = absent ]; then
    echo "absent $p (confirmed: Vault has no metadata)"
    continue
  fi
  echo "found  $p"
  if [ "$APPLY" = 1 ]; then
    vault kv metadata delete "$p" >/dev/null || { echo "FAIL: delete of $p failed" >&2; fail=1; continue; }
    after="$(kv_state "$p")" || { fail=1; continue; }
    if [ "$after" = absent ]; then echo "gone   $p"; else echo "FAIL: $p metadata still present after delete" >&2; fail=1; fi
  fi
done

[ "$APPLY" = 1 ] || echo "dry run: pass --apply to delete"
exit "$fail"
