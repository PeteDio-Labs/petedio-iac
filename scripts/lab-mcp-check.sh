#!/usr/bin/env bash
# lab-mcp-check.sh — read-only check of both MCP connectors (PET-827).
#
# It reports what it examined, and exits 1 when any probe fails or cannot run, so a probe
# that reached nothing never reads as a pass. It changes nothing and reads no secret.
#
# Probes:
#   1  edge:     an unauthenticated request to each MCP hostname must return 401
#   2  shim:     the Plane Caddy shim on 235:8790 answers /healthz, probed from LXC 112
#                over SSH, because the shim admits only 112
#   3  listener: lab-agent listens on 237:3017 (only 112 may reach it, so this runs over
#                SSH on the node and uses pct exec)
#   4  tag:      the lab audience tag from Terraform, for lab_agent_access_aud
#
# Usage: ./scripts/lab-mcp-check.sh [--no-tf] [--node pve03]
set -uo pipefail

NO_TF=0
NODE="pve03"
while [ $# -gt 0 ]; do
  case "$1" in
    --no-tf) NO_TF=1 ;;
    --node) NODE="${2:?--node needs a value}"; shift ;;
    -h|--help) printf 'usage: %s [--no-tf] [--node pve03]\n' "${0##*/}"; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"
FAIL=0; RAN=0
ok(){ RAN=$((RAN+1)); printf '  ok    %s\n' "$*"; }
bad(){ RAN=$((RAN+1)); FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$*"; }

echo "== 1. edge (expect 401 unauthenticated)"
for url in https://mcp-plane.pdlab.dev/mcp https://mcp-lab.pdlab.dev/mcp/lab; do
  code="$(curl -s -m 10 -o /dev/null -w '%{http_code}' -X POST "$url" || true)"
  case "$code" in
    401) ok "$url -> 401" ;;
    000) bad "$url -> no answer (DNS, tunnel or network)" ;;
    *)   bad "$url -> $code (want 401; 403 means Access passed and the origin refused)" ;;
  esac
done

# pct runs on a node. pve03 is an unprivileged login, so it needs sudo (lab-verify.sh does the same).
# The default node is the ssh alias pve03; a literal address would use the Mac's default key,
# which pve03 refuses.
if [ "$NODE" = pve03 ]; then PCT="sudo /usr/sbin/pct"; else PCT="pct"; fi
on_node(){ ssh -n -o BatchMode=yes -o ConnectTimeout=8 "$NODE" "$1" 2>&1; }

echo "== 2. Plane shim on 235:8790 (from LXC 112, the only source it admits)"
out="$(on_node "$PCT exec 112 -- curl -s -m 5 -o /dev/null -w '%{http_code}' http://192.168.50.235:8790/healthz")"
case "$out" in
  200) ok "235:8790/healthz from 112 -> 200" ;;
  [0-9][0-9][0-9]) bad "235:8790/healthz from 112 -> $out" ;;
  *) bad "could not run on $NODE: $(printf '%s' "$out" | tr -s '\n' ' ' | cut -c1-160)" ;;
esac

echo "== 3. lab-agent MCP listener on 237:3017 (via $NODE, pct exec 237)"
if out="$(on_node "$PCT exec 237 -- ss -ltn 'sport = :3017'; $PCT exec 237 -- grep -c '^LAB_ACCESS_AUD=' /etc/lab-agent/lab-agent.env")"; then
  if printf '%s' "$out" | grep -q ':3017'; then ok "237 listens on :3017"; else bad "237 does not listen on :3017 (lab_agent_access_aud empty, so MCP is off)"; fi
  last="$(printf '%s\n' "$out" | tail -1)"
  case "$last" in
    1) ok "env file carries LAB_ACCESS_AUD" ;;
    0) bad "env file has no LAB_ACCESS_AUD" ;;
    *) bad "could not read the env file: $(printf '%s' "$last" | cut -c1-120)" ;;
  esac
else
  bad "could not run on $NODE: $(printf '%s' "$out" | tr -s '\n' ' ' | cut -c1-160)"
fi

echo "== 4. audience tags (Terraform outputs; not secrets)"
if [ "$NO_TF" = 1 ]; then
  echo "  skipped (--no-tf)"
else
  command -v terraform >/dev/null || bad "terraform not in PATH"
  # The S3 backend needs the MinIO keys. Take them from the environment, else from Vault with
  # the token from $VAULT_TOKEN or the macOS Keychain item (the source deploy-pete-bot.sh uses).
  if [ -z "${AWS_ACCESS_KEY_ID:-}" ] || [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then
    if [ -z "${VAULT_TOKEN:-}" ] && command -v security >/dev/null; then
      VAULT_TOKEN="$(security find-generic-password -s "${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}" -w 2>/dev/null || true)"
      export VAULT_TOKEN
    fi
    if [ -z "${VAULT_TOKEN:-}" ]; then
      bad "no MinIO keys, no VAULT_TOKEN and no Keychain item: terraform cannot read the state"
    elif command -v vault >/dev/null; then
      AWS_ACCESS_KEY_ID="$(vault kv get -field=access_key kv/iac/minio 2>/dev/null || true)"
      AWS_SECRET_ACCESS_KEY="$(vault kv get -field=secret_key kv/iac/minio 2>/dev/null || true)"
      export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
    fi
  fi
  if terraform -chdir="$HOMELAB" init -reconfigure -input=false >/dev/null 2>&1; then
    for o in lab_mcp_subdomain_access_aud; do
      v="$(terraform -chdir="$HOMELAB" output -raw "$o" 2>/dev/null || true)"
      if printf '%s' "$v" | grep -Eq '^[0-9a-f]{64}$'; then ok "$o = $v"; else bad "$o is empty or not 64 hex"; fi
    done
  else
    bad "terraform init failed (check the MinIO keys)"
  fi
fi

echo
echo "examined $RAN probes, $FAIL failed"
[ "$FAIL" = 0 ] && [ "$RAN" -gt 0 ]
