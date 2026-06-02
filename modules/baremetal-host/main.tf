# Reusable BARE-METAL host declaration — the EC2(GPU)-equivalent for physical
# machines Terraform cannot *create*. TF declares the host (identity + the desired
# IP) in state and, optionally and gated, triggers the Ansible run that does the
# actual OS/IP config. This is the homelab stand-in; the AWS swap replaces this
# module with aws_instance (+ route53 + security_group).
#
# Deliberately NO dns/firewall resources: this homelab has no TF-manageable DNS
# (internal DNS was decommissioned — hosts are reached by IP) and the host
# firewall is UFW configured by Ansible (roles/ollama-service). See docs/GOTCHAS.md.
#
# terraform_data is a built-in resource (no provider). `input` holds the declared
# shape so the host's identity + target IP are diffable desired-state.

resource "terraform_data" "this" {
  input = {
    hostname     = var.hostname
    ipv4_address = var.ipv4_address
    mac_address  = var.mac_address
    description  = var.description
  }
}

# Gated Ansible bridge (OFF by default). When run_ansible = true, a local-exec on
# the operator/runner box shells out to ansible-playbook — NOT a remote-exec/host
# provisioner (the PLAN's documented bare-metal anti-pattern). Default false keeps
# plan-on-PR / apply-on-merge side-effect-free (mirrors the postgres_ready
# two-phase gate): the netplan renumber + OS config are run MANUALLY via ansible/
# until/unless a runner is wired to reach this host with ansible + inventory + key.
resource "terraform_data" "ansible" {
  count = var.run_ansible ? 1 : 0

  triggers_replace = {
    hostname     = var.hostname
    ipv4_address = var.ipv4_address
    playbook     = var.ansible_playbook
  }

  provisioner "local-exec" {
    working_dir = var.ansible_dir
    command     = "ansible-playbook ${var.ansible_playbook} --limit ${var.hostname} -i ${var.ansible_inventory}"
  }

  depends_on = [terraform_data.this]
}
