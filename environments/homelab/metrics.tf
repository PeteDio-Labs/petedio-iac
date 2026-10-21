# metrics (LXC 240): the lab's metrics store and, in a later change, its dashboards (PET-708).
# Prometheus scrapes node_exporter on every host. See roles/prometheus for what it stores and why
# the store is Prometheus from apt.
#
# WHY 240 / .240. 240 is the first free number in the 24x block: 241 openfaas, 242 and 243 are
# destroyed, 244 is down, 245 minio-data, 246 is reserved for notes-svc (minio-data.tf), 247
# claude and 248 codex. It is free in vault/Hosts/hosts-inventory.md and in Terraform. VMID =
# last IP octet, as everywhere else here.
#
# WHY pve02 (Pedro decides; this is the recommendation from the PET-712 survey). pve02 had 11 GB
# of free memory, 89 GB free on `local-lvm` and 8 GB of 15.5 GB allocated on 2026-10-20. pve03
# had 8.5 GB free with 44 GB allocated on 15.3 GB, and it stops every guest at 02:45 for its
# backup. pve02 backs up in snapshot mode, and survives the loss of pve03, which is when the
# metrics matter most. It breaks "pve02 holds only media guests" (runner-233 and netboot-239
# already do).
#
# ⚠ THIS IS A GREENFIELD CREATE. The plan is SUPPOSED to say "1 to add" for the container, and
# apply-on-merge creates it. Check the three fields below that have each broken a container in
# this lab: datastore_id, target_node and template_file_id.
#
#   datastore_id = "local-lvm"  pve02 has a thin pool. Its `local` directory store sits on the
#                               root disk, which was full on 2026-09-28 (PET-529).
#   target_node  = "pve02"      On the bpg provider, target_node and datastore_id force
#                               REPLACEMENT, so changing either later rebuilds the container.
#   template     13.1-2         pve02 carries 13.1-2 and not 13.6-1 (`pveam list local`,
#                               2026-09-28). Templates live on each node's own `local`.
#
# The 20 GiB disk holds 90 days of samples for about 25 hosts (a few GiB at 30 s) plus Grafana.

module "metrics" {
  source = "../../modules/proxmox-lxc"

  vm_id        = 240
  hostname     = "metrics-240"
  ipv4_address = "192.168.50.240/24"

  cores            = 2
  memory_dedicated = 2048
  disk_size        = 20

  datastore_id     = "local-lvm"
  target_node      = "pve02"
  template_file_id = "local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst"
  ssh_public_key   = var.ssh_public_key

  # True, as on usaa.tf: the module sets `started = var.start_on_boot` and Terraform manages run
  # state, so false would stop a hand-started container on the next apply.
  start_on_boot = true

  description = "Metrics store and dashboards (PET-708). Managed by Terraform; services by configure-metrics.yml."
}

output "metrics_id" {
  description = "VMID of the metrics container."
  value       = module.metrics.vm_id
}
