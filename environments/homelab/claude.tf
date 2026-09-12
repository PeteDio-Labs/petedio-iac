# claude (LXC 247) — the homelab's Claude Code host. Its whole job is to run Claude Code
# with Remote Control on, so a session can be driven from claude.ai/code or the Claude
# phone app while the process itself stays here.
#
# WHY A HOST AND NOT A LAPTOP. Remote Control is not a cloud runtime. The session runs on
# the machine that starts it, and the web and mobile clients are a window onto that
# process — so a session on the Mac ends when the lid closes, and takes its working tree,
# its shell state and its place in the task with it. On an LXC it survives all three.
#
# Same TF/Ansible split as every other app LXC: TF owns existence + hardware + network;
# everything inside (Node.js, Claude Code, gh, the mirrored workspace repos, the
# per-project remote-control units) is Ansible — ansible/playbooks/configure-claude-code.yml
# + roles/claude-code.
#
# VMID 247 = next free in the .24x compute/AI block; VMID = last IP octet. The four
# before it are all spoken for, and two of them only look free:
#   241  openfaas          live
#   242  ex-resume-242     removed in PET-307, but tickets and runbooks still name it —
#                          the same reason plane.tf took 235 over a free-but-loaded 234
#   243  ex-waterfast      destroyed in PET-306 (2026-08-24) with fast.pdlab.dev; only its
#                          DB row in databases.tf survives. Same "still named everywhere"
#                          caution as 242
#   244  ex-tailscale      died with pve01 and MUST NOT be recreated (see tailscale.tf)
#   245  minio-data        live
#   246  reserved          claimed for the still-unbuilt notes-svc by minio-data.tf
#
# Debian 13, PINNED to the 13.6-1 image media-dash.tf, palworld.tf and runner.tf all use —
# not the module default 13.1-2, which nothing else in this environment still asks for. The
# template must exist on pve03's `local` storage or apply-on-merge fails at create:
#   pveam update && pveam download local debian-13-standard_13.6-1_amd64.tar.zst
#
# NO out-of-band post-create step, DELIBERATELY. Nothing here runs Docker, so this host
# needs no `features{}` (nesting/keyctl) and no device passthrough — the two things a
# Proxmox API token cannot set (hardcoded root@pam check, docs/GOTCHAS.md). Claude Code is
# a Node process; containerizing it would buy nothing and would cost a scripts/lxc-features
# step on every rebuild. Keep it that way: if something here ever seems to want Docker,
# that is the moment to re-read this paragraph.
#
# NO CLOUDFLARE ROUTE AND NO UFW RULE, DELIBERATELY. Remote Control never opens an inbound
# port. The session registers with the Anthropic API over outbound HTTPS and polls for
# work, so reaching it from a phone needs no ingress here at all — which is why this host
# is both the most remotely-accessible box in the lab and the one exposing the least.
# SSH to it over the tailnet (pete-pi-1 advertises 192.168.50.0/24), as with plane-235.
#
# APPLYING THIS FILE DOES NOT GIVE YOU A WORKING HOST, and no play can finish the job
# either. Remote Control requires an interactive claude.ai login — it refuses API keys and
# `claude setup-token` tokens alike — so the rollout is deliberately two-phase: the play
# installs everything and leaves the units STOPPED, then an operator signs in over SSH and
# re-runs with `-e claude_remote_enable=true`. The sequence, including what to click, is
# ansible/roles/claude-code/README.md.

# Sized against real headroom, not appetite: pve03 is a laptop with ~15 GiB of RAM already
# carrying 16 guests at ~6 GiB, and it holds Vault, Postgres, Authentik, Plane and both
# runners. 4 GiB dedicated leaves the platform tier its margin. An OOM on this node is not
# a lost Claude session, it is a lost lab.

module "claude_code" {
  source = "../../modules/proxmox-lxc"

  vm_id            = 247
  hostname         = "claude-247"
  ipv4_address     = "192.168.50.247/24"
  ssh_public_key   = var.ssh_public_key
  target_node      = var.target_node
  cores            = 4
  memory_dedicated = 4096
  memory_swap      = 2048
  disk_size        = 40
  datastore_id     = "local"
  template_file_id = "local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst"
  description      = "Claude Code host — runs `claude remote-control` so sessions are drivable from claude.ai/code and the Claude app. Managed by Terraform."
}

output "claude_id" {
  description = "VMID of the Claude Code container."
  value       = module.claude_code.vm_id
}
