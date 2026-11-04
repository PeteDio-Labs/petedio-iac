#!/usr/bin/env bash
# retire-usaa-vault.sh — delete the USAA tracker's Vault secrets after it is torn down (PET-590).
#
# RUN IT AFTER petedio-iac#600 has applied. That apply removes the usaa database entry whose
# ephemeral read of kv/db/usaa would otherwise fail, and destroys LXC 238, the only consumer.
# The script checks the container is gone before it deletes anything.
#
# WHAT IT DELETES (permanently, with every version): `vault kv metadata delete`.
#   kv/db/usaa            the app's database password
#   kv/services/usaa      bearer tokens, calendar address, deploy key, notify token
# WHAT IT KEEPS BY DEFAULT
#   kv/services/usaa-minio   the scoped key for the usaa-statements bucket, which was kept
#                            because it holds the only copy of the statements. Pass
#                            --with-minio once Pedro has exported or removed the bucket.
#
# It prints key NAMES and never a value. Vault token: $VAULT_TOKEN, else the macOS Keychain
# item $VAULT_TOKEN_KEYCHAIN_ITEM. Run only on Pedro's word.
#
# Usage:
#   ./scripts/retire-usaa-vault.sh             # dry run: lists what it would delete
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

# Guard: the container must be gone, or the app would lose its secrets while running.
if ping -c1 -W2 192.168.50.238 >/dev/null 2>&1; then
  echo "FAIL: 192.168.50.238 still answers. Apply petedio-iac#600 first." >&2
  exit 1
fi
echo "ok: 192.168.50.238 does not answer"

fail=0
for p in "${PATHS[@]}"; do
  if keys="$(vault kv get -format=json "$p" 2>/dev/null | python3 -c 'import json,sys; print(",".join(sorted(json.load(sys.stdin)["data"]["data"])))' 2>/dev/null)"; then
    echo "found  $p  keys: $keys"
  else
    echo "absent $p (nothing to delete)"
    continue
  fi
  if [ "$APPLY" = 1 ]; then
    vault kv metadata delete "$p" >/dev/null
    if vault kv get "$p" >/dev/null 2>&1; then
      echo "FAIL: $p still readable after delete" >&2; fail=1
    else
      echo "gone   $p"
    fi
  fi
done

[ "$APPLY" = 1 ] || echo "dry run: pass --apply to delete"
exit "$fail"
