#!/usr/bin/env bash
# tf-state-repoint-node.sh — reconcile terraform state with where guests ACTUALLY are.
#
#   ./scripts/tf-state-repoint-node.sh [root-dir]      # default environments/homelab
#   ./scripts/tf-state-repoint-node.sh ../media-iac/environments/media
#
# WHY THIS EXISTS. A container's node is not something terraform can change.
# `node_name` and `datastore_id` both force REPLACEMENT on the bpg provider:
#
#   # module.poker_api...this must be replaced
#   ~ node_name = "pve02" -> "pve03" # forces replacement
#   Plan: 1 to add, 0 to change, 1 to destroy.
#
# So placement is changed with `pct migrate` and reconciled here afterwards.
# Editing `target_node` and applying would destroy and rebuild the guest. The plan
# gates refuse that, which is why CI goes red rather than eating a container --
# but red CI is the symptom, and this is the repair.
#
# WHY NOT A `removed` / `import` BLOCK. Repointing needs the row dropped and
# re-adopted, and terraform refuses to pair them for an address the config still
# declares:
#
#   Error: Removed resource still exists
#   ...was removed, but it is still declared in configuration.
#
# An `import` block cannot adopt over an existing row either. This is the residue
# after that test -- see the IaC-over-hand-fixes rule in CLAUDE.md before adding
# anything else here.
#
# GENERIC BY DESIGN. It does not carry a list of guests or a target node. It reads
# the live cluster, compares against state, and repoints whatever disagrees. That
# is deliberate: the pve01 repair scripts hardcoded both, so each only ever fixed
# the estate it was written for, and petedio-media-iac's state sat broken for a
# day because a sibling script `cd`'d somewhere else (PET-332).
set -euo pipefail

ROOT="${1:-environments/homelab}"
cd "$(dirname "$0")/.."
[ -d "$ROOT" ] || { echo "no such root: $ROOT" >&2; exit 1; }

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
  export VAULT_ADDR="https://192.168.50.223:8200"; export VAULT_TOKEN="$ROOT_TOKEN"
  export VAULT_SKIP_VERIFY=true
  # Match CI, or the pool resource shows a spurious destroy.
  export TF_VAR_manage_resource_pool=true
  [ -n "$AWS_ACCESS_KEY_ID" ] || { echo "could not read MinIO keys from Vault" >&2; exit 1; }
  echo "credentials resolved from Vault"
fi

cd "$ROOT"
terraform init -input=false -reconfigure >/tmp/repoint-init.log 2>&1 || {
  tail -15 /tmp/repoint-init.log; echo "terraform init failed" >&2; exit 1; }

BACKUP="/tmp/tfstate-pre-repoint-$(date +%Y%m%d-%H%M%S).json"
terraform state pull > "$BACKUP"
echo "state backed up to $BACKUP (serial $(python3 -c "import json;print(json.load(open('$BACKUP'))['serial'])"))"

# Live truth. /cluster/resources answers for every node in one call, so a guest
# that moved is found wherever it landed -- never assume the node you asked.
LIVE=$(ssh -n -o ConnectTimeout=10 pve02 \
  'pvesh get /cluster/resources --type vm --output-format json' 2>/dev/null)
[ -n "$LIVE" ] || { echo "could not read /cluster/resources" >&2; exit 1; }

PLAN=$(STATE="$(cat "$BACKUP")" LIVE="$LIVE" python3 <<'PYEOF'
import json, os
live = {str(r["vmid"]): r["node"] for r in json.loads(os.environ["LIVE"]) if r.get("vmid")}
state = json.loads(os.environ["STATE"])
for r in state.get("resources", []):
    if r.get("type") != "proxmox_virtual_environment_container":
        continue
    mod = r.get("module", "")
    for i in r.get("instances", []):
        a = i.get("attributes", {})
        vmid, have = str(a.get("vm_id") or ""), a.get("node_name") or ""
        if not vmid:
            continue
        want = live.get(vmid)
        addr = f"{mod}.{r['type']}.{r['name']}" if mod else f"{r['type']}.{r['name']}"
        if want is None:
            print(f"GONE\t{addr}\t{vmid}\t{have}")
        elif want != have:
            print(f"MOVE\t{addr}\t{vmid}\t{have}\t{want}")
PYEOF
)

if [ -z "$PLAN" ]; then
  echo "nothing to repoint — state already matches the live cluster."; exit 0
fi

echo
echo "== repointing =="
while IFS=$'\t' read -r kind addr vmid have want; do
  [ -z "$kind" ] && continue
  if [ "$kind" = "GONE" ]; then
    echo "  ⚠ $addr (vmid $vmid) is in state on $have but exists on NO node."
    echo "    Not touching it: a missing guest is a different problem from a moved"
    echo "    one, and 'state rm' here would silently drop a container you may want"
    echo "    back. Remove it from config with a 'removed' block instead."
    continue
  fi
  echo "  $addr  $have -> $want  (vmid $vmid)"
  terraform state rm "$addr" >/dev/null
  terraform import -lock=false "$addr" "$want/$vmid" >/dev/null
  echo "    imported as $want/$vmid"
done <<< "$PLAN"

echo
echo "Now run a plan and READ IT."
echo "Expect one '+ vm_id = <n>' per imported guest — terraform import populates"
echo "'id' but not 'vm_id'. It is an in-place write of a value already true, the"
echo "plan gate passes it, and one apply converges it."
echo
echo "To undo:  terraform state push $BACKUP"
