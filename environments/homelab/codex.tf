# codex (LXC 248) — the Codex reviewer for the PET-549 proof of concept. A Claude session
# implements and opens a pull request, Codex reviews it with comments, and Pedro decides the
# merge (2026-10-01). This host runs the Codex CLI headless (`codex exec --json`) under a non-root user with no sudo.
#
# Same TF/Ansible split as claude.tf: TF owns existence, hardware, network and the guest
# firewall; everything inside (the Codex binary, the session user, AGENTS.md, config.toml)
# is Ansible — ansible/playbooks/configure-codex.yml + roles/codex.
#
# VMID 248 = next free in the Agents (24x) block; VMID = last IP octet. 246 is claimed for
# notes-svc by minio-data.tf, and 247 is claude-247. The 1xx block is for media guests, so
# the first draft's LXC 120 was wrong (PET-549).
#
# Debian 13, pinned to the 13.6-1 image claude.tf uses. The template is on pve03's `local`
# storage. Sized below claude-247: Codex is one Rust binary, and pve03 carries the platform
# tier on ~15 GiB of RAM.
#
# ONE out-of-band post-create step: `nesting=1`, which an API token cannot set
# (docs/GOTCHAS.md). Codex's sandbox needs it, and roles/lxc-features declares it. The
# reason is in ansible/roles/codex/README.md, "Test the sandbox".
#
# APPLYING THIS FILE DOES NOT GIVE YOU A WORKING WORKER. Pedro signs Codex in to OpenAI
# over SSH once the play has run. The sequence is ansible/roles/codex/README.md.

module "codex" {
  source = "../../modules/proxmox-lxc"

  vm_id                      = 248
  hostname                   = "codex-248"
  ipv4_address               = "192.168.50.248/24"
  ssh_public_key             = var.ssh_public_key
  target_node                = var.target_node
  cores                      = 2
  memory_dedicated           = 2048
  memory_swap                = 1024
  disk_size                  = 30
  datastore_id               = "local"
  template_file_id           = "local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst"
  network_interface_firewall = true
  description                = "Codex worker (PET-549 POC) — runs `codex exec` on codex/* branches; egress limited to the internet by the guest firewall. Managed by Terraform."
}

# --- Egress: the internet, Plane's API, pete-bot's notify port, and nothing else on the lab's networks
# PET-553 asks for DNS, GitHub, the OpenAI API and the package registries, and nothing else
# in 192.168.50.0/24 or the .86 mesh. GitHub's and OpenAI's addresses rotate, and an
# IP-based firewall cannot name them, so the rules deny every private range instead and let
# the rest of the internet through. That keeps the boundary the item cares about, the lab,
# without a rule list that goes stale.
#
# ⚠ THESE RULES DO NOTHING UNTIL THE DATACENTER FIREWALL IS ON. The CI token holds no
# Sys.Modify, so Terraform cannot turn it on. ansible/playbooks/configure-pve-firewall.yml
# does, over the nodes' root SSH, and turns each node's own host firewall off first, so
# only guests with a firewall config are filtered (PET-553).
#
# Rules are first-match, top to bottom. Conntrack accepts replies on its own, so the
# inbound policy can drop everything but SSH.

resource "proxmox_virtual_environment_firewall_options" "codex" {
  node_name    = var.target_node
  container_id = module.codex.vm_id

  enabled       = true
  input_policy  = "DROP"
  output_policy = "ACCEPT"
  macfilter     = true
  ipfilter      = false
  dhcp          = false
  ndp           = false
  radv          = false
}

resource "proxmox_virtual_environment_firewall_rules" "codex" {
  node_name    = var.target_node
  container_id = module.codex.vm_id

  # Inbound: SSH only. Pedro signs Codex in over it, and Ansible configures the host over it.
  rule {
    type    = "in"
    action  = "ACCEPT"
    proto   = "tcp"
    dport   = "22"
    comment = "SSH for the operator and Ansible"
  }

  # Outbound DNS to the router, the one LAN address this host may reach.
  rule {
    type    = "out"
    action  = "ACCEPT"
    proto   = "udp"
    dest    = "192.168.50.1"
    dport   = "53"
    comment = "DNS to the router"
  }

  rule {
    type    = "out"
    action  = "ACCEPT"
    proto   = "tcp"
    dest    = "192.168.50.1"
    dport   = "53"
    comment = "DNS to the router (TCP)"
  }

  # Plane's API on plane-235, the one LAN service this host may reach (PET-553). The
  # reviewer reads a work item and posts a comment as its own `codex` Plane user, through
  # the `plane` CLI that roles/codex installs. Port 8080 only: SSH and Postgres on .235
  # stay behind the reject below. It sits above that reject, because rules are first-match.
  rule {
    type    = "out"
    action  = "ACCEPT"
    proto   = "tcp"
    dest    = "192.168.50.235"
    dport   = "8080"
    comment = "Plane API on plane-235, for the codex Plane user"
  }

  # pete-bot's HTTP port on media-dash-237 (PET-584). A review session runs `notify-pedro`,
  # from roles/notify-pedro, to DM Pedro through POST /v1/notify, which its own bearer gates.
  # Port 3015 only: SSH, the metrics port and every other service on .237 stay behind the
  # reject below.
  rule {
    type    = "out"
    action  = "ACCEPT"
    proto   = "tcp"
    dest    = "192.168.50.237"
    dport   = "3015"
    comment = "pete-bot /v1/notify on media-dash-237, for notify-pedro"
  }

  # Every private and tailnet range: the LAN (.50), the mesh (.86), the tailnet's CGNAT
  # block and link-local. REJECT rather than DROP, so a refused request fails at once
  # instead of hanging until its timeout, and the PET-553 egress test reads a clear refusal.
  rule {
    type    = "out"
    action  = "REJECT"
    dest    = "192.168.0.0/16"
    comment = "No LAN (.50) or mesh (.86)"
  }

  rule {
    type    = "out"
    action  = "REJECT"
    dest    = "10.0.0.0/8"
    comment = "No private 10/8"
  }

  rule {
    type    = "out"
    action  = "REJECT"
    dest    = "172.16.0.0/12"
    comment = "No private 172.16/12"
  }

  rule {
    type    = "out"
    action  = "REJECT"
    dest    = "100.64.0.0/10"
    comment = "No tailnet"
  }

  rule {
    type    = "out"
    action  = "REJECT"
    dest    = "169.254.0.0/16"
    comment = "No link-local"
  }

  depends_on = [proxmox_virtual_environment_firewall_options.codex]
}

output "codex_id" {
  description = "VMID of the Codex worker container."
  value       = module.codex.vm_id
}
