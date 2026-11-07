# Audit backups and test a restore

`lab-verify.sh` reads the 06:00 `backup-health` verdict on pve02 and pve03. That verdict does not
cover pve01, a guest with no archive, or Vault's snapshot. Two playbooks cover the rest (PET-834).
Both run through `lab-action.yml` on a runner, so no session needs a Mac prompt.

## Audit: are backups happening and recent?

To read the state, dispatch `lab-action.yml` with `action=playbook_check` and
`target=backup-audit.yml`. The run needs no approval and changes nothing.

The play fails when any of these does not hold:

- Every node that hosts a guest has an enabled cluster backup job.
- Every guest, except the VMIDs excluded on purpose (247), has an archive on the share younger
  than 30 hours.
- The last `vault-snapshot.service` run on LXC 223 succeeded and left a snapshot younger than
  30 hours.

The last lines print how many jobs, guests, archives and snapshots the play read. A pass with
zero archives read is a failure, not a pass.

## Restore test: does an archive open?

To run the preflight, dispatch `action=playbook_check` with `target=restore-test-backup.yml`. The
preflight finds the newest archive of guest 102, tests its compression stream, reads the guest
config inside it and refuses a config with a mount point, device or `lxc.*` line.

To restore, dispatch `action=playbook_apply` with the same target. The run waits for the
`lab-write` approval. After the tap, the play:

1. Restores the archive to VMID 9990 on pve02's `local-lvm` with `--start 0` and a fresh MAC.
2. Mounts the root filesystem, counts files and reads `/etc/os-release`.
3. Unmounts and destroys VMID 9990, then confirms the cluster guest count is unchanged.

The scratch guest never starts, so it takes no address. The play refuses to run when VMID 9990
already exists, and it never destroys a guest it did not create.

To change the source guest or the scratch VMID, edit the `vars` block of the playbook.
