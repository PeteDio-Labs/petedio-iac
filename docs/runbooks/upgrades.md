# Upgrade runbooks

Each section gives what to run, what it examines and what a bad result looks like. Threads run
the `lab-action` steps. A `playbook_check` needs no approval. A `playbook_apply` waits for your tap
on the `lab-write` job. The Mac and 247 run only the host steps marked as theirs (`PET-849`).

Run `lab_updates` before and after every section. Its last line gives the counts of hosts
examined, unreadable and skipped, so read those, not only the package total.

## Patch OS security updates in every guest (`patch-guests.yml`, `PET-908`)

- **Run:** `playbook_check patch-guests.yml`, then `playbook_apply patch-guests.yml`.
- **What it does:** per node, one node at a time, it runs `files/security-patch.sh` inside each
  running LXC through `pct exec`. It upgrades security packages only. It never reboots and never
  runs `apt autoremove`.
- **No service restarts:** an apply blocks every maintainer-script restart (`policy-rc.d`), so a
  patched library stays loaded until you restart its service. Restart the service in a planned
  window, or reboot the guest when a row says `reboot=yes`.
- **Held packages:** the script counts but does not upgrade Vault, Postgres, Docker, containerd,
  MinIO, GPU drivers, kernels and Proxmox packages. The sections below upgrade them.
- **Expected:** each node's summary line says how many guests it listed and read, how many have
  no `apt`, and how many need a reboot. The play fails when any chosen guest returns no result.
- **Bad:** a guest that reports `reboot=yes` needs a planned reboot. A check simulates from the
  guest's cached lists and cannot run `apt-get update`, so a guest with old lists undercounts.
  Read `lists=<days>` in each row. An apply updates the lists first.
- **Not covered:** the nodes (`schedule-node-upgrade.yml` owns them, gated on a fresh backup),
  Alpine guests such as 112 (`apk` marks no security fix), and pi1.

### pi1 (a 247 or Mac host step)

The `lab-action` runner holds no key for pi1 (`PET-849`). Run the same script from a session
that has one, from a fresh `main` of `petedio-iac`:

```sh
ssh pi1 'sudo sh -s plan'  < ansible/playbooks/files/security-patch.sh
ssh pi1 'sudo sh -s apply' < ansible/playbooks/files/security-patch.sh
```

The last line starts with `RESULT|`. Post that line, and nothing else, on the PET item. Kuma
runs on pi1, so check the Kuma page loads afterwards.

## Restart the guests after patching (`restart-guests.yml`, `PET-908`)

- **Run:** `playbook_check restart-guests.yml`, then `playbook_apply restart-guests.yml`.
- **Why:** `patch-guests.yml` restarts no service, so a patched library stays loaded until the guest
  restarts. Guests on pve03 restart nightly under the backup job's `mode: stop`, and Vault's two
  unseal watchers reopen it. The play covers the guests nothing restarts: 240, 246, 110, 236 and 247.
- **Order:** the list in `roles/guest-restart/defaults/main.yml`, one guest at a time, 247 last
  because its restart ends the Remote Control sessions. The first guest that does not come back
  healthy stops the play.
- **Healthy means:** the guest answers `pct exec` after its restart marker clears, any
  configured URL or unit answers, systemd has finished booting, Docker answers, no container is starting or unhealthy, no unit has failed that was not already failed (by name), and as many containers run as before. Plex is checked by its unit, `plexmediaserver`; run `lab_verify` afterwards, because it probes Plex at its mesh address.
- **Before you apply:** the play cannot read Plex or qBittorrent. Read `lab_probe mtrace` for
  Plex sessions and unfinished torrents, and name what you saw.
- **Not covered:** 233, a runner. A restart of the runner that executes the job ends the job.
  A session on 247 or the Mac restarts it between runs with `ssh pve02 pct reboot 233`.

## Upgrade Authentik (119) (`upgrade-authentik.yml`, `PET-908`)

- **Run:** `playbook_check upgrade-authentik.yml`, then `playbook_apply upgrade-authentik.yml`.
- **Version:** one line, `authentik_version` in `ansible/roles/authentik/defaults/main.yml`. The
  tag sits inline on the `image:` lines of `server`, `worker` and `ldap` in
  `/opt/authentik/docker-compose.yml`. `.env` holds no tag. The running version was 2024.12.5
  after the hand patch of 2026-11-12.
- **What a check examines:** the current tag, that the three images share it, and that every
  compose container reports healthy. It refuses a downgrade, a jump of more than one minor and
  a minor outside the reviewed list in `authentik-upgrade.sh`. It changes nothing.
- **What an apply does:** takes a `vzdump` archive of 119 unless one under 30 minutes old exists,
  copies the compose file, dumps the database to `/root/authentik-pre-<version>-<time>.sql.gz`,
  edits the tag, pulls, then recreates `server`, `worker` and `ldap` one at a time and waits for
  each to be healthy. It restores the compose file when the tag edit, the config check, the pull or the first recreate fails. It waits 300 s per service, because the first server start runs migrations. On a timeout it changes nothing more, because the old image against a half-migrated database is worse than a slow start.
- **Bad:** a rollback restores the image only. A migration that already ran stays, so recover
  from the `vzdump` archive. The play never reboots. 119 has a pending `dbus` reboot (Pedro,
  2026-11-12: do it when convenient), so reboot 119 in the window of the first minor bump.
- **Path from 2024.12:** 2025.2, 2025.4, 2025.6, 2025.8, 2025.10, 2025.12, 2026.2, 2026.5,
  2026.8. One PR per minor changes `authentik_version` and cites that minor's release notes. Read
  each minor's breaking changes before you open its PR; 2025.2 notes the Source stage change
  and the frozen `:latest` tag, and says to upgrade outposts with the instance.
- **Open drift:** the compose and `.env` headers say "managed by Ansible", and this role now
  owns the tag only. The embedded outpost still shows a stale `auth.toastedbytes.com` host, and
  Docker's apt key sits in legacy `/etc/apt/trusted.gpg`. Neither changes here.

## Upgrade Vault (223)

Planned. A Vault upgrade restarts the service, which seals it. The playbook upgrades the
package, then runs the unseal step in `configure-vault-unseal.yml`, and fails until
`vault status` reports `Sealed false`. It takes a snapshot first (`vault-snapshot.yml`).

## Upgrade the media apps

Planned. Media lives in `petedio-media-iac`, which has its own playbooks and in-use guards
(`media-lifecycle`). Each app upgrade runs a check first and refuses while Plex has a session
or qBittorrent has an unfinished torrent. Per `MED-5..10`, fold the Debian 12 to 13 upgrade of
104, 105, 109 and 110 into the guest moves instead of upgrading in place twice.
