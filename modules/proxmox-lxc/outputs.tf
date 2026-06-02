output "vm_id" {
  description = "VMID of the container."
  value       = proxmox_virtual_environment_container.this.vm_id
}

output "ipv4_address" {
  description = "Static IPv4 address (CIDR) assigned to the container."
  value       = var.ipv4_address
}

output "hostname" {
  description = "Container hostname."
  value       = var.hostname
}
