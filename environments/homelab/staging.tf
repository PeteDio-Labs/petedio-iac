# staging-249 (LXC 249) — staging copy of the pdlab.dev portfolio, for checking UI changes
# before they reach S3 and CloudFront (repo petedio-labs/pdlabs-portfolio).
#
# The host serves a built `dist/` with Caddy on :8080. Terraform owns existence, hardware and
# network only. Caddy, the site root and the file layout belong to
# ansible/playbooks/configure-staging.yml. The deploy that fills the site root is a separate
# change, because it runs portfolio code on a self-hosted runner and needs Pedro's OK.
#
# WHY 249. VMID = last IP octet, as everywhere here. 230 to 239 are used or burned
# (234 and 238 were destroyed and their vault notes keep the number; do not reuse), and 240
# to 248 are taken. 249 is the next free number, checked against the live cluster.
#
# Check the three fields that have each broken a container in this lab, as media-dash.tf lists:
# datastore_id "local" (pve03 has no thin pool), bridge vmbr0, and a template present on the node.

module "staging" {
  source = "../../modules/proxmox-lxc"

  vm_id        = 249
  hostname     = "staging-249"
  ipv4_address = "192.168.50.249/24"

  cores            = 1
  memory_dedicated = 512
  disk_size        = 4

  datastore_id     = "local"
  target_node      = "pve03"
  template_file_id = "local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst"
  ssh_public_key   = var.ssh_public_key
  description      = "Staging copy of pdlab.dev (portfolio). Managed by Terraform; app by configure-staging.yml."
}

output "staging_id" {
  description = "VMID of the portfolio staging container."
  value       = module.staging.vm_id
}
