# iac-canary (LXC 250) — the throwaway proof resource for the Workflow B test.
#
# Its only job: be the thing that `terraform apply` creates on merge, proving the
# plan-on-PR -> apply-on-merge choreography end-to-end against the fresh MinIO
# state backend and the self-hosted runner. Safe to destroy after (see GATE B).
#
# Carries the bpg/proxmox gotchas so it doubles as the reference pattern:
#   - `features {}` omitted (Proxmox API rejects feature-setting via token;
#     Ansible/ssh-as-root sets nesting/keyctl out-of-band — see docs/GOTCHAS.md).
#   - lifecycle.ignore_changes for the attributes bpg can't round-trip.
#   - bridge = vmbr1: on pve01 the LAN/uplink bridge is vmbr1, NOT vmbr0
#     (vmbr0 = eno1, a different segment with no gateway). See GOTCHAS.

resource "proxmox_virtual_environment_container" "canary" {
  description   = "iac-canary — Workflow B proof container (PET-5). Disposable."
  node_name     = var.target_node
  vm_id         = 250
  unprivileged  = true
  start_on_boot = false
  started       = true

  initialization {
    hostname = "iac-canary"

    ip_config {
      ipv4 {
        address = "192.168.50.250/24"
        gateway = "192.168.50.1"
      }
    }

    dns {
      servers = ["192.168.50.1"]
      domain  = "local"
    }

    user_account {
      keys = [trimspace(var.ssh_public_key)]
    }
  }

  operating_system {
    template_file_id = "local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst"
    type             = "debian"
  }

  cpu {
    cores = 1
  }

  memory {
    dedicated = 512
    swap      = 256
  }

  disk {
    datastore_id = "sdb3-storage"
    size         = 4
  }

  network_interface {
    name     = "eth0"
    bridge   = "vmbr1"
    firewall = false
  }

  # See canary.tf header + docs/GOTCHAS.md. These attributes are creation-time
  # inputs that don't round-trip (template, ssh keys) or are set out-of-band by
  # Ansible (features) — ignoring them keeps plan clean on subsequent runs.
  lifecycle {
    ignore_changes = [
      operating_system[0].template_file_id,
      initialization[0].user_account,
    ]
  }
}

output "canary_id" {
  description = "VMID of the canary container — proof that apply ran."
  value       = proxmox_virtual_environment_container.canary.vm_id
}
