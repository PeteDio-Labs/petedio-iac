# netboot (LXC 238): the network-boot server that installs Proxmox VE on ollama-host
# (.12) to make it pve04 (PET-528).
#
# WHY 238 / .238, AND WHY pve02
#
# 238 is the next free number in the 23x apps block, and VMID = last IP octet, as
# everywhere else here. It can't be .12: ollama-host holds that address and is the machine
# this server boots. It sits on pve02 by Pedro's decision, so the netboot server doesn't
# share a node with pve03, which stages the ollama-host backups during the rebuild.
#
# WHAT IT SERVES. dnsmasq in proxy-DHCP mode answers PXE requests from an allowlist of MAC
# addresses and leaves address assignment to the router, so the router's DHCP config stays
# untouched. It chains a BIOS or UEFI client into iPXE, and iPXE fetches the Proxmox VE
# installer kernel, initrd and ISO over HTTP. The file layout and kernel parameters are
# Proxmox's own, from `proxmox-auto-install-assistant prepare-iso --pxe-loader ipxe`.
# Ansible owns all of it: playbooks/configure-netboot.yml.
#
# ⚠ DON'T MERGE UNTIL PET-529 CLOSES. pve02's root disk was full on 2026-09-28 (the
# ollama-backups NFS mount dropped and vzdump filled `/`). Apply-on-merge creates this
# container on pve02, and a create against a full root disk fails partway.
#
#   datastore_id = "local-lvm"  pve02 has a thin pool, with 85 GB free on 2026-09-28.
#                               pve02's `local` directory store sits on the root disk.
#   target_node  = "pve02"      On the bpg provider, target_node and datastore_id force
#                               REPLACEMENT, so changing either later rebuilds the container.
#   template     13.1-2         pve02 carries 13.1-2 and not 13.6-1 (`pveam list local`,
#                               2026-09-28). Templates live on each node's own `local`.
#
# ⚠ TEMPORARY. Once pve04 has joined the cluster (PET-528 step 6), delete this file along
# with inventory/netboot.yml, roles/netboot and playbooks/configure-netboot.yml.

module "netboot" {
  source = "../../modules/proxmox-lxc"

  vm_id        = 238
  hostname     = "netboot-238"
  ipv4_address = "192.168.50.238/24"

  # The disk holds the 1.7 GB installer ISO, its extracted kernel and initrd, and the
  # packages. nginx serves the ISO with sendfile, so memory doesn't scale with its size.
  cores            = 1
  memory_dedicated = 512
  disk_size        = 8

  datastore_id     = "local-lvm"
  target_node      = "pve02"
  template_file_id = "local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst"
  ssh_public_key   = var.ssh_public_key
  description      = "Network-boot server for the pve04 install (PET-528). Managed by Terraform; services by configure-netboot.yml. Temporary."
}

output "netboot_id" {
  description = "VMID of the netboot container."
  value       = module.netboot.vm_id
}
