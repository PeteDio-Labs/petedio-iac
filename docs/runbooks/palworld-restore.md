# Restore the Palworld world

Palworld is retired from the lab (`PET-779`). CT 234, its panel, its tunnel and its Ansible
roles are gone from `main`. The world save stays in MinIO so Pedro and Sonia can play again
when a new update ships. This runbook says where the save lives and how to put it on a new
server.

## Where the save lives

- **Bucket:** `palworld-backups` on minio-221 (`192.168.50.221:9000`).
- **Final export:** `palworld-final-<timestamp>.tar.gz`, with a `.sha256` sidecar. The
  timestamp is the run of `scripts/export-palworld-world.sh` that preceded the destroy.
  The PR thread and the `PET-779` item record the exact name.
- **Older archives:** `palworld-final-20260723T011311Z.tar.gz` and
  `palworld-backup-20260723T001041Z.tar.gz` stay in the bucket. Nothing deletes them.
- **Also:** pve03 `vzdump` archives of CT 234 exist until the backup retention prunes them.

The archive layout is `palworld-final-<ts>/Saved/SaveGames/0/<worldguid>/Level.sav`, plus
`Saved/Config`, which carries `DedicatedServerName` for the world.

## Before the destroy

1. On 247, run `scripts/export-palworld-world.sh`. It stops `palworld.service`, archives
   `Pal/Saved`, uploads it, downloads it again and compares sha256 checksums.
2. Confirm the script printed `stored copy matches`.
3. Only then set the repo variable `ALLOW_DESTROY=true`, merge, and reset it to `false`.

## Restore onto a new server

1. Recover the removed Ansible code from the last commit that carried it:
   `git show 1f6acdf:ansible/roles/palworld/tasks/main.yml`. Check out that commit into a
   worktree to get the `palworld` role, `configure-palworld.yml` and the inventory files.
   Do not run `git checkout 1f6acdf -- .` on `main`.
2. Create the host and converge it with the `palworld` role.
3. Run `ARCHIVE=<name> scripts/restore-palworld-world.sh` against the host. It refuses to
   overwrite an existing world, verifies the archive and checks where `Level.sav` lands.
4. Start the server and check `worldguid` and the day count on `/v1/api/info`. A day count
   of zero means a fresh world: stop before it writes.
