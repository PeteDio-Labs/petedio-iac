# runner (LXC 232) — self-hosted GitHub Actions runner, ORG-scoped to PeteDio-Labs.
# Runner labels: self-hosted,linux,x64,homelab. Runs Workflow B (this workspace's
# terraform plan/apply) AND the Co-latro app CI/CD, from INSIDE the homelab so it
# can reach the Proxmox API + MinIO + Nexus + Vault.
#
# PET-79: re-registered from petedio-iac-REPO scope to ORG scope so it serves all
# PeteDio-Labs repos, and Docker was installed (configure-runner-docker.yml) so app
# CI can build images + use service containers. The legacy org runner ci-runner
# (LXC 116, no Docker, not in IaC) was deregistered + stopped. FOLLOW-UP: the runner
# REGISTRATION is still out-of-band (org reg token + config.sh) — TF owns only the
# LXC; an IaC-managed registration is not yet wired.
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
