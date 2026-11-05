# Restore the Palworld world

Palworld is retired from the lab (`PET-779`). CT 234, its panel, its tunnel and its Ansible
roles are gone from `main`. The world save stays in MinIO so Pedro and Sonia can play again
when an update ships. This runbook says where the save lives and how to put it on a replacement
server.

## Where the save lives

- **Bucket:** `palworld-backups` on minio-221 (`192.168.50.221:9000`).
- **Final export:** `palworld-final-20261105T011601Z.tar.gz` (58 MiB, 156 save files, world
  `0BA20FE97DF7472AADFD2237B5B4EFFC`), with a `.sha256` sidecar. Its sha256 is
  `2c069fafea436782506b7a5506dc8bb140cbd1ca70f8ff745976031af46cb835`. The Mac ran
  `scripts/export-palworld-world.sh` for it on 2026-11-05, before the destroy.
- **Older archives:** `palworld-final-20260723T011311Z.tar.gz` and
  `palworld-backup-20260723T001041Z.tar.gz` stay in the bucket. Nothing deletes them.
- **Also:** pve03 `vzdump` archives of CT 234 exist until the backup retention prunes them.

The archive layout is `palworld-final-<ts>/Saved/SaveGames/0/<worldguid>/Level.sav`, plus
`Saved/Config`, which carries `DedicatedServerName` for the world.

## Before the destroy

1. On the Mac, with `VAULT_ADDR` and `VAULT_TOKEN` exported, run `scripts/export-palworld-world.sh`.
   247 lacks `mc`, `vault` and the ansible key, so the script aborts there. It stops `palworld.service`, archives
   `Pal/Saved`, uploads it, downloads it again and compares sha256 checksums.
2. Confirm the script printed `stored copy matches`.
3. Only then set the repo variable `ALLOW_DESTROY=true`, merge, and reset it to `false`.

## Restore onto a replacement server

1. Recover the removed Ansible code from the last commit that carried it:
   `git show 1f6acdf:ansible/roles/palworld/tasks/main.yml`. Check out that commit into a
   worktree to get the `palworld` role, `configure-palworld.yml` and the inventory files.
   Do not run `git checkout 1f6acdf -- .` on `main`.
2. Create the host and converge it with the `palworld` role.
3. Run `ARCHIVE=<name> scripts/restore-palworld-world.sh` against the host. It refuses to
   overwrite a world already on the server, verifies the archive and checks where `Level.sav` lands.
4. Start the server and check `worldguid` and the day count on `/v1/api/info`. A day count
   of zero means a fresh world: stop before it writes.
