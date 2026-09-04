#!/usr/bin/env bash
# Repoint terraform state from the dead pve01 onto pve02, and drop the guests
# that no longer exist anywhere.
#
# WHY THIS EXISTS. pve01 was removed from the cluster after its RAID controller
# failed. Terraform state still records ten containers as living on it, so every
# plan dies at refresh with:
#
#   Error: hostname lookup 'pve01' failed
#
# Config alone cannot fix that -- terraform refreshes each resource against the
# node named in ITS STATE. The supported repair is state rm + import, per
# resource, which is what this does.
#
# It is deliberately not run by CI: it rewrites state, and MinIO versioning on
# the tfstate bucket is the only undo.
#
# Credentials are resolved here rather than assumed. The terraform S3 backend
# needs the MinIO keys, and without them it falls back to the AWS credential
# chain and fails with "No valid credential sources found" plus an EC2 IMDS
# error, which reads as an AWS problem and is not.
set -euo pipefail

cd "$(dirname "$0")/../environments/homelab"

if [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then
  ROOT_TOKEN="$(security find-generic-password -s vault-root-token -a vault-223 -w 2>/dev/null)" || {
    echo "no Vault root token in the Keychain (vault-root-token / vault-223)" >&2; exit 1; }
  vget() {
    curl -sk -m 10 -H "X-Vault-Token: $ROOT_TOKEN" \
      "https://192.168.50.223:8200/v1/kv/data/iac/$1" 2>/dev/null \
      | python3 -c "import sys,json;print((json.load(sys.stdin).get('data',{}).get('data') or {}).get('$2',''))"
  }
  export AWS_ACCESS_KEY_ID="$(vget minio access_key)"
  export AWS_SECRET_ACCESS_KEY="$(vget minio secret_key)"
  export TF_VAR_proxmox_api_token="$(vget proxmox api_token)"
  export TF_VAR_ssh_public_key="$(vget lxc-ssh public_key)"
  export TF_VAR_cloudflare_api_token="$(vget cloudflare api_token)"
  export TF_VAR_cloudflare_account_id="$(vget cloudflare account_id)"
  export TF_VAR_cloudflare_zone_id="$(vget cloudflare zone_id)"
  export TF_VAR_cloudflare_tunnel_id="$(vget cloudflare tunnel_id)"
  export TF_VAR_cloudflare_palworld_tunnel_id="$(vget cloudflare palworld_tunnel_id)"
  export VAULT_ADDR="https://192.168.50.223:8200"
  export VAULT_TOKEN="$ROOT_TOKEN"
  export VAULT_SKIP_VERIFY=true
  # Match CI, or the pool resource shows a spurious destroy.
  export TF_VAR_manage_resource_pool=true
  [ -n "$AWS_ACCESS_KEY_ID" ] || { echo "could not read MinIO keys from Vault" >&2; exit 1; }
  echo "credentials resolved from Vault"
fi

BACKUP="/tmp/tfstate-pre-repoint-$(date +%Y%m%d-%H%M%S).json"
terraform state pull > "$BACKUP"
echo "state backed up to $BACKUP (serial $(python3 -c "import json;print(json.load(open('$BACKUP'))['serial'])"))"

# Guests that survived on pve02: the container is real, only the state's idea of
# which node it sits on is wrong. rm + import corrects that without touching the
# running guest.
EXISTS="
module.authentik.proxmox_virtual_environment_container.this|119
module.minio_data.proxmox_virtual_environment_container.this|245
module.openfaas.proxmox_virtual_environment_container.this|241
module.plane.proxmox_virtual_environment_container.this|235
module.poker_api.proxmox_virtual_environment_container.this|230
module.postgres_host.proxmox_virtual_environment_container.this|231
module.vault.proxmox_virtual_environment_container.this|223
"

# Guests that exist nowhere. Removing them from state makes terraform plan to
# CREATE them from config -- which is the intent, but read that plan before
# applying it. runner-232 is declared on pve03 now; registry-106 needs its
# lxc.idmap solved first (see the CLAUDE.md banner) and tailscale-244 is
# superseded by the subnet router on pete-pi-1.
GONE="
module.registry.proxmox_virtual_environment_container.this|106
module.runner.proxmox_virtual_environment_container.this|232
module.tailscale.proxmox_virtual_environment_container.this|244
"

echo
echo "== repointing guests that exist on pve02 =="
while IFS='|' read -r addr vmid; do
  [ -z "$addr" ] && continue
  echo "  $addr  (vmid $vmid)"
  terraform state rm "$addr" >/dev/null
  terraform import -lock=false "$addr" "pve02/$vmid" >/dev/null
  echo "    imported as pve02/$vmid"
done <<< "$EXISTS"

echo
echo "== dropping guests that exist nowhere =="
while IFS='|' read -r addr vmid; do
  [ -z "$addr" ] && continue
  echo "  $addr  (vmid $vmid) -- terraform will plan to create this"
  terraform state rm "$addr" >/dev/null
done <<< "$GONE"

echo
echo "== remaining references to pve01 in state =="
terraform state pull | grep -c '"node_name": "pve01"' || echo "0"

echo
echo "Now run a plan and READ IT. It must show no destroy of a running guest."
echo "To undo:  terraform state push $BACKUP"
