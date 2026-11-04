# Nightly vzdump job for the guests on pve01 (PET-834).
#
# pve02 and pve03 each carry a hand-made job (02:30 and 02:45 Eastern). pve01 joined the
# cluster on 2026-10-23 (PET-528) with no job, so CT 246 has no backup. This declares the
# pve01 job as config. It does not import the other two: they run in different modes and
# the pve03 job excludes 247, so declaring them is a separate change.
#
# Mode is snapshot because ollama-246 sits on pve01's `local-lvm` (LVM thin), which
# snapshots. A directory store would need `stop` (vault/Systems/backups-and-vzdump-modes.md).
# Schedule is 03:15 so the run starts after the pve02 and pve03 jobs and does not compete
# with them for the NFS store. Retention is the cluster default, so no prune_backups.
#
# GATED, like pool.tf. Two hand steps must happen before MANAGE_BACKUP_JOB=true:
#   1. The IaC token must hold the privileges that create a cluster backup job.
#      Unverified; a 403 on create would otherwise fail apply-on-merge for everything.
#   2. pve01 must mount the ollama-backups store. The storage is a `dir` at
#      /mnt/ollama-backups, and pve01 serves the data from /srv/backups, so pve01 needs
#      a bind mount (docs/runbooks/pve01-cutover.md, "After it passes"). Without it the
#      storage is inactive on pve01 and the job fails each night.
# Run the plan with the gate on and read it before you set the repo variable.

resource "proxmox_backup_job" "pve01" {
  count = var.manage_backup_job ? 1 : 0

  id       = "pve01-nightly"
  node     = "pve01"
  all      = true
  schedule = "*-*-* 03:15"
  storage  = "ollama-backups"
  mode     = "snapshot"
  compress = "zstd"
  enabled  = true

  notes_template = "{{guestname}} ({{node}})"
}
