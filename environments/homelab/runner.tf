# runner (LXC 232) — self-hosted GitHub Actions runner for PeteDio-Labs/petedio-iac.
# Runner labels: self-hosted,linux,x64,homelab. Runs the terraform plan/apply
# jobs against this very workspace (Workflow B), from INSIDE the homelab so it
# can reach the Proxmox API + MinIO state backend.
#
# PLAN calls this "VM 232"; we implement it as an LXC — the old ci-runner (116)
# proved the native-runner-in-LXC pattern (no Docker, no features needed, the
# cleanest resource in the workspace). VMID 232 = apps block (.232).
#
# Provisioning lifecycle: TF owns existence + hardware + network. Ansible owns
# everything inside (actions-runner registration, terraform/ansible/gh install)
# — see ../../ansible/playbooks/github-runner.yml (ported from homelab-infra).
#
# Bootstrap note: this resource is applied LOCALLY once (terraform apply -target)
# to break the CI chicken-and-egg — the first PR needs a runner that doesn't
# exist yet. After it's registered, all subsequent plan/apply run on it.

resource "proxmox_virtual_environment_container" "runner" {
  description   = "GitHub Actions self-hosted runner (petedio-iac). Managed by Terraform."
  node_name     = var.target_node
  vm_id         = 232
  unprivileged  = true
  start_on_boot = true
  started       = true

  initialization {
    hostname = "runner-232"

    ip_config {
      ipv4 {
        address = "192.168.50.232/24"
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
    cores = 2
  }

  memory {
    dedicated = 2048
    swap      = 512
  }

  disk {
    datastore_id = "sdb3-storage"
    size         = 20
  }

  # vmbr1 = the LAN/uplink bridge on pve01 (vmbr0 is eno1, no gateway). See GOTCHAS.
  network_interface {
    name     = "eth0"
    bridge   = "vmbr1"
    firewall = false
  }

  lifecycle {
    ignore_changes = [
      operating_system[0].template_file_id,
      initialization[0].user_account,
    ]
  }
}

output "runner_id" {
  description = "VMID of the self-hosted runner container."
  value       = proxmox_virtual_environment_container.runner.vm_id
}
