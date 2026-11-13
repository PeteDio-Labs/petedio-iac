# Runbook — three-machine lab split

> **Status: phase 1 is written and unapplied (MED-6).** Phases 2-7 hold the order and the
> headline steps only. Each gets its exact commands and rollback in its own change, after the
> phase before it has run and shown what the real node reports.

The lab ends as three nodes: `pve-media` (a Jonsbo N5 NAS at 192.168.50.13 that holds all of
media), `pve-compute` (the GPU box, today's `pve01` at .12) and `pve-core` (the laptop `pve03`
at .10, which holds the control plane). The Dell `pve02` retires. Never reuse a retired node
name; `pve01` was reused once and left stale notes behind (see `ansible/inventory/pve01.yml`).

| Phase | What | Down | Needs |
|---|---|---|---|
| 1 | Build `pve-media` and join it | Nothing | Parts delivered |
| 2 | Media cutover to `pve-media`; ends the USB single point of failure | Plex, qBittorrent, arr: 2-3 h | Phase 1, clean scrubs |
| 3 | Library to the HDD pool, backups to the NAS | Media: 10-20 min | Phase 2, HDDs past burn-in |
| 4 | Rebuild `pve01` as `pve-compute` | Ollama: 3-4 h | Phase 3 |
| 5 | Retire `pve02` | Nothing | Phase 4 |
| 6 | Harden `pve03` | Nothing | Phase 5 |
| 7 | Rename `pve03` to `pve-core` | About 5 min per control-plane guest | Phase 5 |

Run one phase per lab day (Friday to Monday). Only one node is down at a time. Read
`vault/Hosts/hosts-inventory.md` and run `scripts/lab-verify.sh` before and after each phase.

## Why media leaves USB first

On 2026-11-08 at 22:04 EST, pve02's ORICO USB enclosure (JMicron 152d:0567) re-enumerated with no
disconnect logged. The disks came back as `sdf`-`sdj` and both ZFS pools suspended. Plex could not
read most of the library for 75 minutes. `zpool clear media` and `zpool clear downloads` recovered
the pools without a reboot; `media` reported no data errors and `downloads` held 4 permanent errors
in pool metadata only, no files. It was the first drop since pve02 booted on 2026-10-23.
`vault/Incidents/2026-11-08-media-pools-suspended.md` has the record.

What this changes in the plan:

- **The enclosure is a live single point of failure for all media data.** Phase 2 moves the five
  SSDs onto the N5's SATA and HBA bays and ends it. Run phase 2 as soon as phase 1 is done, and do
  not wait for the HDDs to finish burn-in: phase 2 needs none of them.
- **Size from today's numbers.** `media` holds 1.32 TB used and 1.29 TB free (49% of the pool). The
  370 GB figure in the vault (2026-09-21) is out of date.
- **Put the arr stack beside the pools.** pve03's hard NFS mounts hang Sonarr, Radarr and Bazarr
  whenever pve02's pools stall. Phase 2 migrates 104, 105, 109, 222, 101 and 102 onto `pve-media`,
  where `/mnt/media` is local ZFS, which removes that coupling.
- **Until phase 2 runs,** a suspended pool on pve02 is fixed with `zpool clear <pool>`. mtrace's
  `pool_health` tool (petedio-media-control#24) reads the pool state from inside 236 and reports
  `SUSPENDED` with that fix text. It never reports an unknown state as `ONLINE`.

Before phase 2, Pedro runs `zpool scrub media` and `zpool scrub downloads` on pve02 and reads
`zpool status -v` for both once they finish. The scrubs have not run since the incident. Do not
export a pool with a scrub in progress or with errors you have not read.

## Code that ships before the hardware

These land unapplied so build day needs only hardware.

- `ansible/planned/pve-media.yml` stages `pve-media` in group `pve_media`, **outside
  `ansible/inventory/`**. `ansible.cfg` loads that whole directory and every host in it joins
  `all`, which `collect-cve-inventory.yml` and `configure-ssh-ca.yml` target. A planned host
  there would make the CVE snapshot refuse to refresh. No playbook names `pve_media`, and
  `pve_new` and `pve_gpu` stay untouched.
- `ansible/roles/mesh-usb-bridge` takes any interface name and fails with the interfaces it
  found when the name is absent.
- `scripts/hdd-burnin.sh` burns in the HDDs, and `scripts/test-hdd-burnin.sh` checks its
  verdicts offline.

## Phase 1: build the NAS and join it

**Goal:** a fourth cluster node with an empty RAIDZ2 pool and a tested mesh bridge, while
production runs untouched. Quorum goes from 2 of 3 to 3 of 4.

### Before you start

1. Confirm the parts arrived: B760-P board, CPU, 32 GB RAM, 500 GB NVMe, LSI 9300-8i in IT mode,
   two SFF-8643 breakout cables, PCIe x1 i226 NIC, four 16 TB HDDs.
2. Start the HDD burn-in first, because it takes days. Fit only the HDDs and the HBA if the
   board is not ready; any Linux with `smartmontools` and `e2fsprogs` works for this step.
3. Check that the 9300-8i is real and in IT mode: `sas3flash -list` shows `IT` firmware and a
   `SAS3008` chip. A card that reports `IR` or no firmware version is wrong. Put a fan on its
   heatsink.

### Steps

1. **Flash the BIOS** to 7D98v16 or later before you fit the CPU.
2. **Fit the hardware.** HBA, boot NVMe, and the i226 NIC for the mesh bridge. Use the PCIe card
   and not a second USB adapter, because Plex's only address rides that port.
3. **Burn in the HDDs.** From the node that holds them:

   ```bash
   scripts/hdd-burnin.sh plan /dev/disk/by-id/ata-<drive1> /dev/disk/by-id/ata-<drive2> ...
   BURNIN_CONFIRM='<value plan printed>' tmux new -d -s burnin \
     "scripts/hdd-burnin.sh run /dev/disk/by-id/ata-<drive1> ..."
   scripts/hdd-burnin.sh report /dev/disk/by-id/ata-<drive1> ...
   ```

   `plan` erases nothing; it lists each serial and prints the `BURNIN_CONFIRM` value. `run`
   erases every named drive. `report` exits 1 on any bad block, failed long test, non-zero
   reallocated, pending or uncorrectable sector, or missing log, and prints how many drives it
   read. Replace a failing drive before phase 3. Drives bought from two batches fail
   independently, so one failure does not condemn the other three.
4. **Install Proxmox VE 9** from the ISO (OpenZFS 2.3 or later, for RAIDZ expansion) onto the
   NVMe. Use hostname `pve-media`, address 192.168.50.13/24, gateway 192.168.50.1.
5. **Set the LAN port.** Read `ip -br link` on the node and set `pve_node_lan_interface` in
   `ansible/planned/pve-media.yml`. Also set `mesh_usb_interface` to the i226 port. Load the
   file with `-i inventory/ -i planned/pve-media.yml` until step 10 moves it.
6. **Run `configure-pve-node.yml`.** Its `hosts:` line names `pve_new`. In the build-day change,
   widen it to `pve_new:pve_media`, merge, and run the play with `--limit pve-media`. Read
   `--list-hosts` first and expect exactly one host.
7. **Build the mesh bridge** and test it before phase 2:

   ```bash
   ansible-playbook -i inventory/ -i planned/pve-media.yml \
     playbooks/configure-mesh-usb-bridge.yml -e mesh_bridge_hosts=pve_media
   # on pve-media, once you are ready to bring it up
   ifreload -a
   ```

   From pi1's `wlan0`, confirm the mesh answers through the new bridge before any guest uses
   it. The Tailscale path stays as the fallback.
8. **Join the cluster:** `pvecm add 192.168.50.10` from `pve-media`. Run `pvecm status` and
   expect 4 nodes, quorum 3.
9. **Create the empty pool**, with by-id paths so a changed `/dev/sdX` name cannot reorder it:

   ```bash
   zpool create -o ashift=12 -O compression=lz4 -O atime=off -O xattr=sa -O acltype=posixacl \
     tank raidz2 /dev/disk/by-id/ata-<d1> /dev/disk/by-id/ata-<d2> \
                 /dev/disk/by-id/ata-<d3> /dev/disk/by-id/ata-<d4>
   zpool status tank
   ```

10. **Move the host into live inventory** (`git mv ansible/planned/pve-media.yml
    ansible/inventory/`) in a PR that also updates the consumers of `all`: confirm
    `collect-cve-inventory.yml` and `configure-ssh-ca.yml` can reach the node first.
11. **Re-pin and authorize the node:** run `configure-lab-runner-known-hosts.yml` and add
    `pve-media` to the lab-runner SSH CA principals (`ansible/inventory/pve03.yml` shows the
    shape), so `lab-verify` can read it.
12. **Update `scripts/lab-verify.sh` first, in the same PR as step 10.** It probes only
    `PVE01`, `PVE02` and `PVE03`, asserts exactly 3 cluster members, and reads 3 node
    firewall directories, so a joined fourth node turns it red. Add `pve-media` to the node
    probes, change the member and `host.fw` counts to 4, and write the node's `host.fw`
    before it joins: a node with none drops its own traffic (PET-528).
13. **Run `scripts/lab-verify.sh`** and expect the new node in its count. A count that does not
    change means the check never reached the node.

### Rollback

Phase 1 changes no production guest. To abandon the build, run `pvecm delnode pve-media` from a
quorate node after you power the NAS off, and remove the `pve_media` entries. The cluster returns
to 2 of 3 quorum.

### Done when

- `pvecm status` shows 4 nodes and quorum 3.
- `zpool status tank` shows `ONLINE` and four drives.
- `hdd-burnin.sh report` shows 4 of 4 passed, or phase 3 is blocked on a replacement.
- `lab-verify.sh` counts `pve-media` and expects 4 members.

## Phases 2-7

Headline steps and the reasoning behind the order. Write each phase's commands when you reach it.

2. **Media cutover.** Vzdump 236 and 110. Stop the arr guests on `pve03` and 236 and 110 on
   `pve02`. Run `zpool export media` and `zpool export downloads` on `pve02`. Move the five SSDs
   into the N5 and `zpool import -d /dev/disk/by-id` both pools. Set `shared=1` on the bind-mount
   points of 236 and 110, because `pct migrate` refuses unshared local bind mounts, then migrate
   them with `--target-storage local-lvm`. Apply the mesh bridge, rerun `petedio-media-iac`'s
   `configure-plex-gpu-dns.yml`, and check `/dev/dri/renderD128` and Plex's identity URL from
   pi1. Migrate 104, 105, 109, 222, 101 and 102. Retire the NFS split.
   *Rollback before the guests move:* `zpool import` on `pve02` and start the guests.
3. **Library to HDDs, backups to the NAS.** `zfs send -R` the media pool into `tank/media` with
   media up, then an incremental during a 10-20 minute stop. Create `tank/backups`, export it over
   NFS, copy `/srv/backups` from `pve01`, and add a `nas-backups` storage. Run one backup and one
   `restore-test-backup.yml` before you disable `ollama-backups`.
4. **Rebuild `pve01` as `pve-compute`.** Backups leave `pve01` first (phase 3). Vzdump 246,
   swap the board into the compact case, reinstall as `pve-compute` at .12, rejoin, and restore
   246. Migrate 248, 233 and 240 onto it. Repoint both Terraform states.
5. **Retire `pve02`.** Confirm `pct list` is empty and no state names it, power it off, and run
   `pvecm delnode pve02`. Remove it from inventory, `lab-verify`, Prometheus, Kuma and the dead
   storages.
6. **Harden `pve03`.** Sensors, a 15-minute battery test, a recorded startup order, a daily local
   vzdump of 223, 231 and 221, a spare USB Ethernet adapter, and a break-glass note
   (`pvecm expected 1`).
7. **Rename `pve03` to `pve-core`.** Optional. Add a temporary QDevice on pi1, migrate the ten
   guests to `pve-media`, reinstall the laptop, migrate them back in startup order, and repoint
   both states. Skip it to keep the name `pve03`; nothing else depends on it.

A Terraform apply cannot move a guest between nodes: `node_name` forces replacement. Move guests
with `pct migrate`, then repoint state with `scripts/tf-state-repoint-node.sh`
(`docs/runbooks/pve03-platform-move.md`). The script is scoped to `environments/homelab`; check
`petedio-media-iac`'s state for the same damage (PET-332).
