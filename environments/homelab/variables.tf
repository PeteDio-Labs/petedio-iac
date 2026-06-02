variable "proxmox_endpoint" {
  description = <<-EOT
    Proxmox API endpoint (https://<node>:8006/). bpg/proxmox reads the PVE
    version from this endpoint and conditionally sends version-gated fields, so
    target the node where the resources actually live (pve01 9.1.x here).
  EOT
  type        = string
  default     = "https://192.168.50.10:8006/"
}

variable "proxmox_api_token" {
  description = "Full token: 'user@realm!tokenid=secret'. Minted via pveum (petedio@pam!petedio)."
  type        = string
  sensitive   = true
}

variable "target_node" {
  description = "Proxmox node where these resources live."
  type        = string
  default     = "pve01"
}

variable "ssh_public_key" {
  description = "SSH public key installed for root inside each LXC (matches the key Ansible logs in with)."
  type        = string
}
