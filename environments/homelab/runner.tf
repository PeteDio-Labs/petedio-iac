# runner (LXC 232) — self-hosted GitHub Actions runner, ORG-scoped to PeteDio-Labs.
# Runner labels: self-hosted,linux,x64,homelab. Runs Workflow B's APPLY-on-merge (this
# workspace) AND the Co-latro app CI/CD, from INSIDE the homelab so it can reach the
# Proxmox API + MinIO + Nexus + Vault.
#
# SECURITY (PET-104): this box can reach the whole 192.168.50.0/24 and holds CI's path to
# Vault, so PR-controlled code must NEVER run on it. .github/workflows/terraform.yml now
# runs PRs on a GitHub-HOSTED runner (no creds, no LAN) and keeps only push-to-main
# (post-merge, trusted) on this self-hosted runner; the github-actions Vault role
# (vault-config/auth.tf) binds main-push only. Two hardening layers remain OPERATOR-only
# (out of scope for IaC here): (a) repo Settings → Actions → "Require approval for all
# outside collaborators" on EVERY repo this org runner serves; (b) an ACL/VLAN limiting
# runner-232 to just Proxmox/MinIO/Vault/Nexus rather than the whole /24. Until (a)/(b)
# land, the org-scoping (PET-79) means every PeteDio-Labs repo is an entry point.
#
# PET-79: re-registered from petedio-iac-REPO scope to ORG scope so it serves all
# PeteDio-Labs repos, and Docker was installed (configure-runner-docker.yml) so app
# CI can build images + use service containers. The legacy org runner ci-runner
# (LXC 116, no Docker, not in IaC) was deregistered + stopped. PET-80: the runner
# REGISTRATION is now codified — ../../ansible/playbooks/configure-runner.yml folds in
# Docker and registers the runner with the org (mint-at-runtime reg token from a
# Vault-stored PAT). TF owns the LXC; that play owns everything inside. Rebuild/register
# path: ../../docs/runbooks/runner-232-rebuild.md.
#
# PLAN calls this "VM 232"; we implement it as an LXC — the old ci-runner (116)
# proved the native-runner-in-LXC pattern (no Docker, no features needed, the
# cleanest resource in the workspace). VMID 232 = apps block (.232).
#
# This is the LXC that modules/proxmox-lxc was generalized FROM; it now consumes
# that module like poker-api (230) and postgres-rds (231). The switch from the
# old inline resource is a pure STATE MOVE (see the moved{} block below) — the
# in-production runner is re-addressed in state, never destroyed/recreated (a
# rebuild would break all CI). `description`/`target_node` are passed explicitly
# so the module reproduces the running container's config exactly: the plan must
# be move-only (0 add / 0 change / 0 destroy).
#
# Provisioning lifecycle: TF owns existence + hardware + network. Ansible owns
# everything inside (actions-runner registration, terraform/ansible/gh install)
# — see ../../ansible/playbooks/github-runner.yml (ported from homelab-infra).
#
# Bootstrap note: this container was applied LOCALLY once (terraform apply -target)
# to break the CI chicken-and-egg — the first PR needs a runner that doesn't
# exist yet. After it's registered, all subsequent plan/apply run on it.

module "runner" {
  source = "../../modules/proxmox-lxc"

  vm_id            = 232
  hostname         = "runner-232"
  ipv4_address     = "192.168.50.232/24"
  ssh_public_key   = var.ssh_public_key
  target_node      = var.target_node
  cores            = 2
  memory_dedicated = 2048
  memory_swap      = 512
  disk_size        = 20
  datastore_id     = "sdb3-storage"
  bridge           = "vmbr1"
  description      = "GitHub Actions self-hosted runner (petedio-iac). Managed by Terraform."
}

# State move: the runner used to be an inline
# proxmox_virtual_environment_container.runner; it's now produced by the module
# at module.runner.proxmox_virtual_environment_container.this. This re-addresses
# the EXISTING container in state — no destroy/recreate of the live runner.
moved {
  from = proxmox_virtual_environment_container.runner
  to   = module.runner.proxmox_virtual_environment_container.this
}

output "runner_id" {
  description = "VMID of the self-hosted runner container."
  value       = module.runner.vm_id
}

# runner-233 (LXC 233) — SECOND self-hosted runner, on pve02 (PET-128). Adds CI capacity on
# both cluster nodes; pve02 gained ~421 GB HDD `pve02-shared` + a debian-12 LXC template in
# PET-127. Mirrors runner-232 (org-scoped to PeteDio-Labs; Docker via
# configure-runner-docker.yml; registration is OUT-OF-BAND — org reg token + config.sh — so
# TF owns only the LXC). This is GREENFIELD (no moved{} block — unlike runner-232, which was
# a state-move of a pre-existing container).
#
# Per-node differences from runner-232 (do NOT copy pve01's values):
#   - target_node  = pve02
#   - bridge       = vmbr0   ← pve02's LAN bridge (single NIC, VLAN-aware); pve01 uses vmbr1,
#                              the OPPOSITE. A container on the wrong bridge can't reach the
#                              gateway. See docs/GOTCHAS.md.
#   - datastore_id = pve02-shared  ← the HDD dir storage added in PET-127.
#   - template_file_id = pve02's debian-12 template. CONFIRM the exact volume ID on pve02
#     (`pvesm list local`); the patch version below is a placeholder. template_file_id is in
#     the module's ignore_changes (create-time only), so it only matters for the first apply.
#
# Out-of-band prerequisites (operator — see the PR Manual steps): SDN.Use for the IaC token
# on pve02's vmbr0 SDN zone (new-NIC create 403s otherwise — GOTCHAS); `pct set 233
# --features nesting=1,keyctl=1` for Docker; the .233 DHCP reservation. Runner registration
# is codified — `ansible-playbook configure-runner.yml --limit runner-233` (PET-80).
module "runner_2" {
  source = "../../modules/proxmox-lxc"

  vm_id            = 233
  hostname         = "runner-233"
  ipv4_address     = "192.168.50.233/24"
  ssh_public_key   = var.ssh_public_key
  target_node      = "pve02"
  cores            = 2
  memory_dedicated = 2048
  memory_swap      = 512
  disk_size        = 20
  datastore_id     = "pve02-shared"
  bridge           = "vmbr0"
  template_file_id = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
  description      = "GitHub Actions self-hosted runner #2 on pve02 (petedio-iac). Managed by Terraform."
}

output "runner_2_id" {
  description = "VMID of the second self-hosted runner container (pve02)."
  value       = module.runner_2.vm_id
}
