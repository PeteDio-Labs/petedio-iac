#!/usr/bin/env bash
# seed-palworld-tunnel-vault.sh — store the palworld-mc cloudflared tunnel token in Vault,
# and print the (non-secret) tunnel UUID the Terraform needs.
#
# The panel binds loopback (PET-266), so palworld.pdlab.dev is served by a connector running
# ON the game host, against its own tunnel. This seeds that connector's runtime token, which
# ansible/playbooks/configure-palworld-tunnel.yml then resolves at deploy time.
#
# Idempotent. The token is never echoed, never passed as an argv (so it stays out of `ps` and
# shell history), and never written to disk.
#   Vault token:   $VAULT_TOKEN, else macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM, else prompt
#   Tunnel token:  prompted (paste the value from Cloudflare Zero Trust -> Tunnels -> palworld-mc)
#
# To ROTATE: refresh the token in the Cloudflare dashboard, re-run this, then on the host
# `cloudflared service uninstall` and re-run configure-palworld-tunnel.yml.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"
VAULT_PATH="${VAULT_PATH:-kv/services/palworld-panel}"
# Non-secret IDs live here; .github/workflows/terraform.yml maps them to TF_VAR_* for CI.
CF_VAULT_PATH="${CF_VAULT_PATH:-kv/iac/cloudflare}"

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
for t in vault python3; do command -v "$t" >/dev/null || die "$t not in PATH."; done

step "Resolving Vault token"
if [ -z "${VAULT_TOKEN:-}" ]; then
  VAULT_TOKEN="$(security find-generic-password -s "$VAULT_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null || true)"
fi
[ -n "${VAULT_TOKEN:-}" ] || { read -rsp "Vault token: " VAULT_TOKEN; echo; }
export VAULT_TOKEN
vault token lookup >/dev/null 2>&1 || die "Vault token invalid / Vault unreachable at $VAULT_ADDR."

step "Reading the tunnel token"
echo "Paste the token from Cloudflare (Zero Trust -> Networks -> Tunnels -> palworld-mc)."
echo "Just the token — not the whole 'cloudflared tunnel run --token ...' line."
read -rsp "Tunnel token: " TUNNEL_TOKEN; echo
[ -n "$TUNNEL_TOKEN" ] || die "empty token."

# Tolerate a pasted full command line anyway — strip everything up to the last space.
TUNNEL_TOKEN="${TUNNEL_TOKEN##* }"

# A cloudflared token is base64 JSON {"a":account,"t":tunnel,"s":secret}. Decoding it proves
# the paste is intact BEFORE it lands in Vault (a truncated token fails at connector start,
# hours later and far from the cause), and yields the UUID Terraform needs. `s` is never shown.
step "Validating the token structure"
TUNNEL_ID="$(
  TOKEN="$TUNNEL_TOKEN" python3 - <<'PY'
import base64, json, os, sys
raw = os.environ["TOKEN"].strip()
try:
    payload = json.loads(base64.b64decode(raw + "=" * (-len(raw) % 4)))
except Exception:
    sys.exit("not valid base64 JSON — re-copy the token")
for key in ("a", "t", "s"):
    if not payload.get(key):
        sys.exit(f"token is missing the '{key}' field — looks truncated")
print(payload["t"])
PY
)" || die "the pasted token did not parse. Re-copy it from the dashboard."
echo "OK — token parses. Tunnel UUID: $TUNNEL_ID"

# patch, NOT put: this path already holds admin_password + panel_ssh_private_key, and a `put`
# replaces the whole secret. Clobbering those breaks configure-palworld-panel.yml's asserts on
# the next deploy — a confusing failure a long way from this script.
step "Writing tunnel_token to $VAULT_PATH (patch — other fields preserved)"
vault kv patch "$VAULT_PATH" tunnel_token="$TUNNEL_TOKEN" >/dev/null
unset TUNNEL_TOKEN

step "Verifying the read-back"
LEN="$(vault kv get -field=tunnel_token "$VAULT_PATH" | wc -c | tr -d ' ')"
[ "$LEN" -gt 1 ] || die "read-back was empty."
echo "tunnel_token present ($LEN bytes). Other fields still on the secret:"
vault kv get -format=json "$VAULT_PATH" \
  | python3 -c 'import sys,json;print("   " + ", ".join(sorted(json.load(sys.stdin)["data"]["data"])))'

# The UUID is NON-secret, but it has to reach the CI runner, and terraform.yml sources every
# TF_VAR from Vault (kv/data/iac/cloudflare -> TF_VAR_cloudflare_palworld_tunnel_id). Exporting
# it in a local shell is not enough: apply-on-merge runs on the runner. And the variable is
# deliberately REQUIRED, so a missing value fails the plan loudly rather than disabling the
# module — which, with the `moved` blocks, would destroy the live Access app and CNAME.
step "Writing palworld_tunnel_id to kv/iac/cloudflare (where CI reads TF_VARs)"
vault kv patch "$CF_VAULT_PATH" palworld_tunnel_id="$TUNNEL_ID" >/dev/null
READBACK="$(vault kv get -field=palworld_tunnel_id "$CF_VAULT_PATH")"
[ "$READBACK" = "$TUNNEL_ID" ] || die "read-back mismatch at $CF_VAULT_PATH."
echo "palworld_tunnel_id = $READBACK"

step "Next"
cat <<EOF
1. Merge petedio-iac#187 — apply moves the Access app + CNAME onto the new tunnel.
   (CI picks the UUID up from $CF_VAULT_PATH automatically; no local export needed.)
2. ansible-playbook -i ansible/inventory ansible/playbooks/configure-palworld-tunnel.yml \\
     -e "cloudflared_tunnel_token=\$(vault kv get -field=tunnel_token $VAULT_PATH)"
3. Merge petedio-palworld-panel#24 (CD deploys PANEL_BIND=127.0.0.1).

For a LOCAL plan/apply, export it yourself:
   export TF_VAR_cloudflare_palworld_tunnel_id=$TUNNEL_ID

palworld.pdlab.dev is down between step 1 and step 2 finishing. Expected.
EOF
