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

## Upgrade Authentik (119)

Not yet declared in Ansible. No role exists, and the compose file's location, tag source and
secret wiring are not captured in the repo (`authentik-import.md`). The tag is bumped by hand
until a role pins it. The role manages the version tag only, backs up the compose file first,
and restarts one service at a time.

## Upgrade Vault (223)

Planned. A Vault upgrade restarts the service, which seals it. The playbook upgrades the
package, then runs the unseal step in `configure-vault-unseal.yml`, and fails until
`vault status` reports `Sealed false`. It takes a snapshot first (`vault-snapshot.yml`).

## Upgrade the media apps

Planned. Media lives in `petedio-media-iac`, which has its own playbooks and in-use guards
(`media-lifecycle`). Each app upgrade runs a check first and refuses while Plex has a session
or qBittorrent has an unfinished torrent. Per `MED-5..10`, fold the Debian 12 to 13 upgrade of
104, 105, 109 and 110 into the guest moves instead of upgrading in place twice.
