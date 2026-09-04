# authentik (LXC 119 / .119) — live SSO/LDAP behind auth.pdlab.dev. Brownfield capture
# into petedio-iac (PET-103 → PET-123) BEFORE the legacy homelab-infra TF state retires
# (PET-50, which this gates). Captured IN PLACE, zero disruption — an SSO/LDAP outage
# breaks every downstream login, so this LXC is never recreated.
#
# Like Nexus (106), this container was created out-of-band (not by modules/proxmox-lxc),
# so it diverges from the greenfield defaults. Values below are the LIVE config, read
# read-only via scripts/proxmox-ro-config.sh pve01 119 (PVEAuditor token — no mutation),
# so the import plans as a no-op without guessing specs. Divergences captured:
#   - os_type = "ubuntu"                 (greenfield default is debian)
#   - network_interface_firewall = true  (net0 has firewall=1; default false would DISABLE it)
#   - mac_address pinned                 (so the import doesn't churn the NIC)
#   - dns_servers=[nameserver], dns_domain="" (CT119 sets a nameserver but NO searchdomain)
# features (nesting,keyctl) are out-of-band on the node and ignore_changed by the module.
# CT119 has no extra mount and no idmap (simpler than Nexus); the NIC is eth0 (default).
#
# TWO-STATE NOTE: LXC 119 currently lives in the OLD homelab-infra TF state too. After the
# import here, the operator must `terraform state rm` it from the OLD state so neither
# state owns the box twice — see docs/runbooks/authentik-import.md. Both the import and the
# state rm are operator-only (the loop never runs import/apply/state mutation).
#
# IMPORT-ONLY (operator — see docs/runbooks/authentik-import.md):
#   terraform -chdir=environments/homelab import \
#     'module.authentik.proxmox_virtual_environment_container.this' pve01/119
# then `terraform plan` MUST be a no-op (modulo the documented cosmetic description field).
# Any add/change/destroy of the LXC, NIC (firewall/MAC), or DNS is a STOP-and-reassess.

module "authentik" {
  source = "../../modules/proxmox-lxc"

  vm_id        = 119
  hostname     = "authentik"
  ipv4_address = "192.168.50.119/24"
  target_node  = var.target_node

  cores            = 2
  memory_dedicated = 2048
  memory_swap      = 512
  disk_size        = 20
  # ⚠ Was sdb3-storage. That LVM group lived on pve01's sdb and is pinned
  # `nodes pve01` in storage.cfg, so it resolves to a node that no longer
  # exists. This container actually runs on local-lvm. Because `disk` is not in
  # the module's ignore_changes, leaving the dead value here reads as a
  # REPLACEMENT of a live container.
  datastore_id = "local-lvm"
  # pve01 used vmbr1 for the LAN; pve02 uses vmbr0. On pve02 vmbr1 is the VXLAN
  # bridge, so this value did not merely point at the wrong name -- it pointed
  # at a tunnel whose far end died with pve01.
  bridge = "vmbr0"

  # Brownfield divergences from the greenfield defaults (captured from live config):
  os_type                    = "ubuntu"
  network_interface_firewall = true
  mac_address                = "BC:24:11:C0:03:DA"
  dns_servers                = ["192.168.50.1"] # live nameserver
  dns_domain                 = ""               # CT119 sets no searchdomain → render none

  # ssh_public_key feeds initialization.user_account, which the module keeps in
  # ignore_changes (bpg never round-trips it on import — see GOTCHAS); passing the
  # standard automation key keeps this consistent with the other LXCs.
  ssh_public_key = var.ssh_public_key

  description = "Authentik SSO/LDAP (auth.pdlab.dev). Brownfield-captured into petedio-iac (PET-123). Managed by Terraform."
}

output "authentik_id" {
  description = "VMID of the Authentik SSO container."
  value       = module.authentik.vm_id
}
