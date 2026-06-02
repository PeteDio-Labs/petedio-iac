# Inputs for the reusable baremetal-host module. TF declares a physical host's
# identity + desired IP; Ansible applies the OS/IP config (see the consuming
# environment's ollama.tf + ../../ansible).

variable "hostname" {
  description = "Host name. Also the Ansible inventory host and the --limit target for the gated bridge."
  type        = string
}

variable "ipv4_address" {
  description = <<-EOT
    Static IPv4 the host should hold, plain (e.g. "192.168.50.240"). Declared here
    as desired-state (diffable, AWS-swappable); ANSIBLE (netplan) is what actually
    applies it — TF does not touch the host's network.
  EOT
  type        = string
}

variable "mac_address" {
  description = "Primary NIC MAC — recorded for the router DHCP reservation + Wake-on-LAN recovery. Not enforced by TF."
  type        = string
  default     = ""
}

variable "description" {
  description = "Human description of the host (shown in state/outputs)."
  type        = string
  default     = "Bare-metal host. OS/IP config by Ansible."
}

variable "run_ansible" {
  description = <<-EOT
    Gate for the Ansible bridge (default false). When false, TF only DECLARES the
    host in state and the OS/IP config (incl. the netplan renumber) is run MANUALLY
    via ../../ansible — matching the repo's TF-then-Ansible convention and keeping
    plan-on-PR / apply-on-merge side-effect-free. Flip true ONLY on an operator or
    runner that can actually reach this host with ansible + inventory + SSH key.
  EOT
  type        = bool
  default     = false
}

variable "ansible_dir" {
  description = "Working dir for the gated ansible-playbook run (relative to the environment dir)."
  type        = string
  default     = "../../ansible"
}

variable "ansible_inventory" {
  description = "Inventory path (relative to ansible_dir) used by the gated bridge."
  type        = string
  default     = "inventory/hosts.yml"
}

variable "ansible_playbook" {
  description = "Playbook (relative to ansible_dir) the gated bridge runs."
  type        = string
  default     = "playbooks/ollama-service.yml"
}
