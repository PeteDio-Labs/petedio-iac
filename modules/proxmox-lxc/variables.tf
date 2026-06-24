# Inputs for the reusable proxmox-lxc module. Generalizes the proven runner (232)
# pattern: an unprivileged Debian LXC on pve01/vmbr1, cloud-init-style init, with
# `features` left to Ansible (the root@pam/API-token gotcha — see docs/GOTCHAS.md).

variable "vm_id" {
  description = "Proxmox VMID. Convention: VMID = last octet of the IPv4 address."
  type        = number
}

variable "hostname" {
  description = "Container hostname (e.g. \"poker-api-230\")."
  type        = string
}

variable "ipv4_address" {
  description = "Static IPv4 address in CIDR form (e.g. \"192.168.50.230/24\")."
  type        = string
}

variable "gateway" {
  description = "Default gateway for the container."
  type        = string
  default     = "192.168.50.1"
}

variable "target_node" {
  description = "Proxmox node where the container lives."
  type        = string
  default     = "pve01"
}

variable "cores" {
  description = "Number of CPU cores."
  type        = number
  default     = 2
}

variable "memory_dedicated" {
  description = "Dedicated memory in MiB."
  type        = number
  default     = 2048
}

variable "memory_swap" {
  description = "Swap in MiB."
  type        = number
  default     = 512
}

variable "disk_size" {
  description = "Root disk size in GiB."
  type        = number
  default     = 20
}

variable "datastore_id" {
  description = "Proxmox datastore for the root disk."
  type        = string
  default     = "sdb3-storage"
}

variable "bridge" {
  description = "Network bridge. vmbr1 = LAN/uplink on pve01 (vmbr0 has no gateway)."
  type        = string
  default     = "vmbr1"
}

variable "network_interface_name" {
  description = <<-EOT
    Guest-side name of the LXC's network interface (the `name=` of `net0`). Default
    "eth0" matches every greenfield consumer, so adding this variable is a no-op for
    them. Brownfield captures override it when the running container uses a different
    name (e.g. the Nexus registry, 106, runs on "eth1") — matching it keeps the import
    a no-op instead of renaming (and so recreating) the live NIC.
  EOT
  type        = string
  default     = "eth0"
}

variable "mac_address" {
  description = <<-EOT
    MAC address for the LXC's network interface. Default null leaves it provider-computed
    — a no-op for greenfield consumers (and an imported MAC is preserved as that computed
    value). Brownfield captures pin the running container's hwaddr so the import plans as a
    guaranteed no-op rather than relying on computed-value preservation.
  EOT
  type        = string
  default     = null
}

variable "network_interface_firewall" {
  description = <<-EOT
    Whether the Proxmox NIC-level firewall is enabled on net0. Default false matches every
    greenfield consumer (the module never enabled it), so adding this variable is a no-op
    for them. Brownfield captures set it true when the running container has `firewall=1`
    (e.g. Authentik, 119) — matching it keeps the import a no-op instead of DISABLING the
    firewall on a live host.
  EOT
  type        = bool
  default     = false
}

variable "template_file_id" {
  description = "OS template volume ID for the container."
  type        = string
  default     = "local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst"
}

variable "os_type" {
  description = <<-EOT
    Proxmox operating_system.type — must match the distro of template_file_id
    (e.g. "debian", "ubuntu"). Default stays "debian" (the value every pre-existing
    consumer was created with) so adding this variable is a no-op for them; the
    agent-loop host (242, Ubuntu LTS per PET-125) is the first to override it.
  EOT
  type        = string
  default     = "debian"
}

variable "ssh_public_key" {
  description = "SSH public key installed for root inside the LXC (matches the key Ansible logs in with)."
  type        = string
}

variable "unprivileged" {
  description = "Whether the container is unprivileged."
  type        = bool
  default     = true
}

variable "start_on_boot" {
  description = "Start the container automatically on node boot (also used as the desired running state)."
  type        = bool
  default     = true
}

variable "dns_servers" {
  description = "DNS resolvers for the container."
  type        = list(string)
  default     = ["192.168.50.1"]
}

variable "dns_domain" {
  description = "DNS search domain for the container."
  type        = string
  default     = "local"
}

variable "description" {
  description = "Container description shown in the Proxmox UI."
  type        = string
  default     = "Managed by Terraform."
}

variable "secondary_network_interface" {
  description = <<-EOT
    Optional SECOND NIC for dual-homing the container onto another segment (e.g. the
    192.168.86.x mesh, PET-168). Default null = single-NIC, so adding this variable is a
    no-op for every existing consumer (the module renders net1 + its ip_config only when
    this is set). Give it no ipv4_gateway: the default route must stay on the primary NIC
    (net0); a second gateway creates two default routes.

      name          guest-side interface name (eth1).
      bridge        Proxmox bridge for the segment (e.g. the .86 mesh bridge).
      ipv4_address  CIDR (e.g. "192.168.86.34/24") or "dhcp".
      ipv4_gateway  usually omitted/null for a secondary NIC.
      firewall      Proxmox NIC-level firewall on net1 (default false).
      mac_address   pin the hwaddr if needed (default null = provider-computed).
  EOT
  type = object({
    name         = optional(string, "eth1")
    bridge       = string
    ipv4_address = string
    ipv4_gateway = optional(string)
    firewall     = optional(bool, false)
    mac_address  = optional(string)
  })
  default = null
}
