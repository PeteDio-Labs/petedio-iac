# Reusable LXC on Proxmox (Debian by default; os_type/template_file_id select the
# distro — agent-loop 242 runs Ubuntu LTS) — the EC2-equivalent building block.
# Generalized from environments/homelab/runner.tf (the proven LXC 232 pattern).
#
# Deliberately NO `features {}` block: Proxmox rejects API tokens for the
# features mutation (root@pam check), so nesting/keyctl are set out-of-band by
# Ansible (`pct set --features nesting=1,keyctl=1`). `features` is in
# ignore_changes so a later apply never strips them. See docs/GOTCHAS.md.

resource "proxmox_virtual_environment_container" "this" {
  description   = var.description
  node_name     = var.target_node
  vm_id         = var.vm_id
  unprivileged  = var.unprivileged
  start_on_boot = var.start_on_boot
  started       = var.start_on_boot

  initialization {
    hostname = var.hostname

    ip_config {
      ipv4 {
        address = var.ipv4_address
        gateway = var.gateway
      }
    }

    dns {
      servers = var.dns_servers
      domain  = var.dns_domain
    }

    user_account {
      keys = [trimspace(var.ssh_public_key)]
    }
  }

  operating_system {
    template_file_id = var.template_file_id
    type             = var.os_type
  }

  cpu {
    cores = var.cores
  }

  memory {
    dedicated = var.memory_dedicated
    swap      = var.memory_swap
  }

  disk {
    datastore_id = var.datastore_id
    size         = var.disk_size
  }

  network_interface {
    name     = "eth0"
    bridge   = var.bridge
    firewall = false
  }

  lifecycle {
    ignore_changes = [
      operating_system[0].template_file_id,
      initialization[0].user_account,
      features,
      # device_passthrough (e.g. /dev/net/tun for faasd's CNI on the openfaas LXC) is set
      # out-of-band like features (scripts/lxc-features-*.sh, `pct set <id> -dev0 ...`) —
      # ignore it so a later apply never strips a manually-added device. See docs/GOTCHAS.md.
      device_passthrough,
    ]
  }
}
