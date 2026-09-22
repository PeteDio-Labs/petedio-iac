# Runbook — Palworld nightly world backup (PET-382)

`ansible/roles/palworld` installs `palworld-backup.timer` on `palworld-234`. Nightly, at
04:10 (plus up to 5 minutes of jitter), it flushes the live world, tars `Pal/Saved`, and
uploads it to the `palworld-backups` bucket on `minio-221`. Before this, the only backups
the world ever had were the two archives someone took by hand the night of the PET-266
cutover — see `scripts/restore-palworld-world.sh`.

This page covers the one step Ansible cannot do for you (seeding the MinIO credential),
what the timer does on its own after that, and the restore drill that proves a backup is
actually restorable, not just uploaded.

## Seed the backup credential

The apply-on-merge runner's Vault role (`openfaas_ci`) grants only `lxc-ssh` and Nexus
credentials — the same gap that keeps it from supplying `palworld_admin_password`. A CI
merge installs the timer and the script regardless, but the service fails every night
with a clear "creds missing" error until you seed them by hand, once.

1. Create a MinIO service account scoped to the `palworld-backups` bucket only (read,
   write, list, delete — no other bucket). Store the pair at
   `kv/services/palworld-backups`, fields `mc_access_key` / `mc_secret_key`.
2. Run the playbook once with the credential as extra-vars:

   ```bash
   cd ansible && ansible-playbook -i inventory/ playbooks/configure-palworld.yml \
     -e '{"palworld_backup_minio_access_key":"…","palworld_backup_minio_secret_key":"…"}'
   ```

   This writes `/etc/palworld-backup.env` (root-only, mode 0600) on `palworld-234`. A
   later CI merge-apply that supplies nothing re-reads this file and keeps the existing
   values — see the preservation task in `ansible/roles/palworld/tasks/main.yml` — so an
   unrelated merge never blanks what you just seeded.

3. Confirm the timer is live:

   ```bash
   ssh root@192.168.50.234 systemctl list-timers palworld-backup.timer
   ```

## What the timer does, and does not, back up

- Runs only while `systemctl is-active palworld` is true. A stopped server is skipped
  with exit 0 — an ordinary outcome, not a failure — because there is no REST API to
  confirm a day count against while the server is down. See the header comment in
  `ansible/roles/palworld/templates/palworld-backup.sh.j2` for why this, not the
  active/stopped split itself, is the actual safety control.
- Refuses to upload when `GET /v1/api/metrics` reports a day count of 0 or unreadable.
  This is the control the work item asked for: it stops a backup caught mid-start, before
  the world has loaded, from looking like a real one.
- Each archive gets a `.sha256` sidecar (verified the same way
  `scripts/restore-palworld-world.sh` already verifies one) and a `.meta.json` sidecar
  carrying `worldguid`, `days`, and `archived_at` — readable without extracting the
  archive, so a future restore can tell which one holds what.
- Retention keeps the newest `palworld_backup_retain` (default 30) archives matching this
  script's own naming (`palworld-backup-<UTC timestamp>.tar.gz`) and prunes the rest, plus
  their sidecars. At ~46 MiB/night this is roughly 1.4 GiB, against the ~17 GB/year an
  unpruned bucket would otherwise accumulate.
- The two PET-266 archives (`palworld-final-…` and `palworld-backup-20260723T001041Z…`)
  are not deleted by this timer directly, but the one matching this script's naming
  pattern ages out of the retention window once 30 nightly runs have landed. That is
  intentional: at that point it is superseded by 30 days of live rolling backups, not
  lost. `palworld-final-…` uses a different prefix and is never counted or pruned by this
  script.

## Prove a restore (the step a timer existing does not satisfy)

PET-382 is done only once an archive this timer produced has actually been restored and
verified — not when the timer merely reports success. Run this against a throwaway host,
never against `palworld-234` itself:

1. Pick a recent archive from the bucket:

   ```bash
   mc ls pal221/palworld-backups | grep '^palworld-backup-' | tail -1
   ```

2. Restore it onto a throwaway target with `scripts/restore-palworld-world.sh`:

   ```bash
   TARGET=<throwaway-host> ARCHIVE=<name from step 1> ./scripts/restore-palworld-world.sh
   ```

   The script refuses to run if the target already has a `SaveGames` directory, verifies
   the sidecar hash, and derives the archive's dated top-level prefix rather than
   assuming one — see its own header comments for why.

3. Converge `configure-palworld.yml` against the throwaway host so
   `DedicatedServerName` is pinned to the restored world, then start the server.
4. The only check that counts, per the script's own closing instructions:

   ```bash
   curl -su admin:<AdminPassword> http://<throwaway-host>:8212/v1/api/info
   ```

   Confirm `worldguid` matches the value recorded in the archive's `.meta.json` sidecar,
   and that the day count is non-zero. A wrong-but-plausible `worldguid` with `days: 0`
   means the server generated a fresh world instead of loading the restored one.

Record the result (which archive, which throwaway host, the `worldguid` and day count
observed) wherever this fleet's restore drills are already tracked, and strike the open
item in `vault/Hosts/234-palworld.md`.
