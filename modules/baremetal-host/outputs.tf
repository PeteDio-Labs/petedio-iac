output "hostname" {
  description = "Declared host name."
  value       = var.hostname
}

output "ipv4_address" {
  description = "Declared static IPv4 address (applied by Ansible)."
  value       = var.ipv4_address
}

output "mac_address" {
  description = "Primary NIC MAC (for the DHCP reservation / Wake-on-LAN)."
  value       = var.mac_address
}
