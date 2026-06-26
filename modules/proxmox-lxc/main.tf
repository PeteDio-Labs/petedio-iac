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

    # DNS is optional: a brownfield container that sets no nameserver/searchdomain
    # (e.g. the Nexus registry 106, which inherits the host's resolv.conf) passes
    # dns_servers = [] so NO dns block is rendered — matching its live config keeps
    # the import a no-op instead of writing resolver config into a live host. Default
    # dns_servers is non-empty, so greenfield consumers render exactly the same block
    # as before (no-op).
    dynamic "dns" {
      for_each = length(var.dns_servers) > 0 ? [1] : []
      content {
        servers = var.dns_servers
        # null when empty so a container that sets a nameserver but NO searchdomain
        # (e.g. Authentik 119) imports as a no-op instead of writing a searchdomain.
        # The default dns_domain is non-empty, so greenfield consumers are unaffected.
        domain = var.dns_domain != "" ? var.dns_domain : null
      }
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
    name     = var.network_interface_name
    bridge   = var.bridge
    firewall = var.network_interface_firewall
    # null (default) → provider-computed, a no-op for greenfield consumers; a brownfield
    # capture pins the running hwaddr so the import doesn't rely on computed-value
    # preservation. See docs/GOTCHAS.md.
    mac_address = var.mac_address
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
      # mount_point: bind-mounting a HOST path into the guest (e.g. Nexus 106's
      # mp0 /mnt/pete/nexus-data -> /nexus-data, an NFS-backed blob store) hits the
      # same root@pam API restriction as features, so it's set out-of-band on the node.
      # Ignore it so an import/apply never tries to strip a load-bearing mount the API
      # token couldn't recreate anyway. Greenfield consumers declare no mounts → no-op.
      # See docs/GOTCHAS.md.
      mount_point,
      # idmap + console: bpg DOES round-trip these on import (the original PET-122
      # assumption that raw lxc.idmap is invisible was wrong — only the apparmor line
      # is). CT106's idmap (host 200 ↔ guest 200) is what makes the NFS blob-store
      # mount writable in-guest — load-bearing, root@pam-only like features; never let
      # an apply strip it. Greenfield consumers declare neither block → no-op.
      idmap,
      console,
    ]
  }
}
