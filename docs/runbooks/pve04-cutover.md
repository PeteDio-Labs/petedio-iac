# pve04 cutover: ollama-host becomes a Proxmox node

This runbook turns the bare-metal ollama-host (`192.168.50.12`) into the Proxmox node
`pve04`, joins it to the cluster, and moves Ollama and petedio-search into the GPU
container `ollama-246` (`192.168.50.246`). The work item is `PET-528`. It ran on
2026-10-23 with Pedro at the console.

## What changes and what stays

| | Before | After |
|---|---|---|
| OS | Ubuntu 24.04 on sda | Proxmox VE 9 on a new 128 GB drive |
| Ollama `:11434` and `:11435`, search `:8526` | `.12`, native | `.246`, in CT 246 on pve04 |
| NVIDIA driver | Ubuntu packages, upgraded by unattended-upgrades | one pinned `.run`, on the node (DKMS) and in the container (userspace) |
| `ollama-backups` NFS store | sda `ubuntu-vg/backup-lv` at `/srv/backups`, served from `.12` | the same LV and address, served by pve04 |
| Recovered WD disk (sdb) | `/mnt/wd-backups`, `/mnt/wd-general` | the same mounts, on pve04 |
| Cluster | pve02 + pve03 + QDevice on pete-pi-1 | pve02 + pve03 + pve04, no QDevice |

Both 1 TB disks are unplugged during the install, so the installer can't see them, and
nothing on them changes. The Ubuntu root on sda stays bootable as the rollback until
part E passes.

**Why no QDevice:** a QDevice must be removed before a node joins. With three nodes,
any two keep quorum, and Proxmox advises against a QDevice when the node count is odd.

**Why an LXC and not a VM:** the node has 16 GB of RAM. A VM with PCI passthrough pins
all of its memory. A container shares the node's memory and kernel module, and it keeps
the two-lane layout that `host_vars/ollama-246.yml` already describes.

## Who runs what

- **Pedro** does the hardware, the installer, and the cluster join (it asks for pve03's
  root password).
- **The Mac session** runs every other host step. 247's key doesn't open `.12`, and
  247 has no root on the nodes (`PET-725`), so the Mac is the fallback here. Each step
  reports with one Plane comment on `PET-528`.
- **CI** creates CT 246 when the PR that declares it merges.

## A. Before the shutdown

1. **Survey** (read-only): disk sizes, exports, units, the cluster's `pveversion`, and
   whether `.246` is free. Gate: the comment is on `PET-528`.
2. **Pin the driver checksum.** On the Mac, run:

   ```sh
   curl -fsSLO https://download.nvidia.com/XFree86/Linux-x86_64/580.178.04/NVIDIA-Linux-x86_64-580.178.04.run
   shasum -a 256 NVIDIA-Linux-x86_64-580.178.04.run
   ```

   Gate: the value is on `PET-528`, and the thread commits it to
   `roles/nvidia-driver/defaults/main.yml`.
3. **Make the USB stick** from the Proxmox VE 9 ISO that matches the cluster's major
   version. Check its sha256 against proxmox.com. Netboot CT 239 is the fallback.
4. **Quiesce the backup store.** These steps unmount it so no node hangs on a dead NFS
   server:
   - On pve02 and pve03, run `pgrep -a vzdump || echo none`. Stop if a backup is running.
   - On pve03, run `pvesm set ollama-backups --disable 1`. The flag is cluster-wide.
   - On pve02 and pve03, run `umount /mnt/ollama-backups`. On pete-pi-1, run
     `sudo umount /mnt/ollama-backups`.
   - On `.12`, stop `petedio-search.service`, `petedio-search-refresh.timer`,
     `ollama.service` and `ollama-1660s.service`, then power off.

   Gate: `findmnt /mnt/ollama-backups` prints nothing on all three clients.

## B. Install (Pedro, at the console)

1. Fit the 128 GB drive. **Unplug the SATA cables of both 1 TB drives.**
2. Boot the USB from the firmware's boot menu (F11 on the MSI X570-A PRO).
3. Install Proxmox VE (Graphical) with these values:
   - Target: the 128 GB drive, ext4. Under **Options**, set `swapsize` 8, `maxroot` 32
     and `minfree` 8. The rest becomes the `local-lvm` thin pool.
   - Country, time zone `America/New_York`, US keyboard.
   - A new root password, kept in the password manager only.
   - Management interface: the onboard NIC, MAC `2c:f0:5d:a2:7f:4f`.
   - Hostname `pve04.<pve03's domain>`, IP `192.168.50.12/24`, gateway `192.168.50.1`,
     and pve03's DNS server.
4. When the installer finishes, power off, plug both 1 TB drives back in, and set the
   firmware to boot the 128 GB drive first.
5. Boot. Gate: `https://192.168.50.12:8006` shows the login page.

## C. Join the cluster (Pedro)

1. Upgrade pve04 to the cluster's version. In pve04's web UI, open **pve04 >
   Updates > Repositories**. Disable the two enterprise repositories, then add the
   **No-Subscription** repository. Then, in pve04's shell, run
   `apt update && apt full-upgrade -y && reboot`.
   Gate: `pveversion` on pve04 matches pve03's major and minor version.
2. On pve03's shell, remove the QDevice: `pvecm qdevice remove`. For the next few
   minutes the cluster has two votes and needs both.
3. On pve04's shell, run `pvecm add 192.168.50.10`. Enter pve03's root password and
   accept the fingerprint.
4. Gate: `pvecm status` on any node shows `Nodes: 3`, `Expected votes: 3` and
   `Quorate: Yes`. The UI shows pve04 online.

## D. Bring the backup store and the GPU node back (Mac session)

Run from the PR branch until it merges, from `ansible/`:

1. `ansible-playbook playbooks/configure-pve04.yml -e nvidia_driver_allow_reboot=true`.
   It ends with "CT 246 does not exist yet". That message is expected at this point.
   Gate: the `nvidia-smi` line lists both UUIDs at `580.178.04`, and `dkms status`
   covers the running kernel.
2. `ansible-playbook playbooks/configure-backup-store.yml`, then
   `ansible-playbook playbooks/configure-wd-disk.yml`.
3. On pve03, run `pvesm set ollama-backups --disable 0`. Remount on pete-pi-1:
   `sudo mount /mnt/ollama-backups`.
4. Gate: `pvesm status --storage ollama-backups` shows `active` on pve02 and pve03,
   and `ls /mnt/ollama-backups/dump | wc -l` matches the survey's count.

Do this part before 02:45 Eastern. That is when the nightly vzdump runs, and while the
store is disabled, every job fails.

## E. Bring up Ollama in CT 246

1. Merge the PR. Apply-on-merge creates CT 246 on pve04. Gate: the apply log shows
   `module.ollama` created, `module.pve04_host` updated in place, and nothing destroyed.
2. From `main`, run:
   - `ansible-playbook playbooks/configure-lxc-features.yml`, then `pct reboot 246` on pve04.
   - `ansible-playbook playbooks/configure-pve04.yml -e lxc_gpu_allow_restart=true`
   - `ansible-playbook playbooks/configure-ollama-246.yml`
   - `./scripts/deploy-search.sh`. It targets the `ollama` group, which holds only ollama-246.
3. Repoint the consumers: `./scripts/deploy-uptime-kuma.sh`, then
   `ansible-playbook playbooks/configure-pete-bot.yml`.
4. Gate: run the `PET-762` probe against `.246:11434`. Warm generation is at least
   60 tok/s, and `/api/ps` shows `size_vram` equal to `size` on both lanes.
   `scripts/lab-verify.sh` passes, including "models fully on GPU" and
   "cluster members".

## Rollback

Before part E passes, you can boot Ubuntu again. Power off, unplug the 128 GB drive,
and boot sda. ollama-host comes back at `.12` with Ollama, search and the export as
they were. Then run `pvecm delnode pve04` on pve03 and re-add the QDevice
(`roles/cluster-qdevice`, through `playbooks/configure-pete-pi.yml`).

## After it passes

- Delete netboot CT 239 and its code (`netboot.tf` says so). The destroy needs the repo
  variable `ALLOW_DESTROY=true`.
- Reclaim the Ubuntu root LV on sda once nobody needs the rollback.
- Give pve04's own guests a backup job. The `ollama-backups` storage is a `dir` at
  `/mnt/ollama-backups`, and pve04 serves the store from `/srv/backups`, so pve04
  needs a bind mount before the storage turns active there.
- Update the vault notes: `012-ollama-host`, a new `pve04` and `246-ollama` note,
  `hosts-inventory`, and `node-roles`.
