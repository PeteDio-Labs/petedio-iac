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
# RUN IT FROM environments/homelab WITH THE USUAL CREDENTIALS EXPORTED.
# It is deliberately not run by CI: it rewrites state, and MinIO versioning on
# the tfstate bucket is the only undo.
set -euo pipefail

cd "$(dirname "$0")/../environments/homelab"

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
