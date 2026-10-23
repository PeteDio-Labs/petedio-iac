# pve01 cutover: ollama-host becomes a Proxmox node

This runbook turns the bare-metal ollama-host (`192.168.50.12`) into the Proxmox node
`pve01`, joins it to the cluster, and moves Ollama and petedio-search into the GPU
container `ollama-246` (`192.168.50.246`). The work item is `PET-528`. It ran on
2026-10-23 with Pedro at the console.

**The name pve01 is reused.** The first pve01, a Dell R620 at `.10`, died on 2026-09-03
and left the cluster. Pedro gave its name to this node on 2026-10-23. The plan used
`pve04` until then, and the installer may have run with that name, so step B6 renames
the node before it joins. Step C2 clears what the R620 left in the cluster filesystem.

## What changes and what stays

| | Before | After |
|---|---|---|
| OS | Ubuntu 24.04 on sda | Proxmox VE 9 on a new 128 GB drive |
| Ollama `:11434` and `:11435`, search `:8526` | `.12`, native | `.246`, in CT 246 on pve01 |
| NVIDIA driver | Ubuntu packages, upgraded by unattended-upgrades | one pinned `.run`, on the node (DKMS) and in the container (userspace) |
| `ollama-backups` NFS store | sda `ubuntu-vg/backup-lv` at `/srv/backups`, served from `.12` | the same LV and address, served by pve01 |
| Recovered WD disk (sdb) | `/mnt/wd-backups`, `/mnt/wd-general` | the same mounts, on pve01 |
| Cluster | pve02 + pve03 + QDevice on pete-pi-1 | pve02 + pve03 + pve01, no QDevice |

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
   - Hostname `pve01.<pve03's domain>`, IP `192.168.50.12/24`, gateway `192.168.50.1`,
     and pve03's DNS server.
4. When the installer finishes, power off, plug both 1 TB drives back in, and set the
   firmware to boot the 128 GB drive first.
5. Boot. Gate: `https://192.168.50.12:8006` shows the login page.
6. If the console prompt reads `pve04 login:`, rename the node. It runs no guest yet,
   so nothing else holds the name:

   ```sh
   hostnamectl set-hostname pve01
   sed -i 's/\bpve04\b/pve01/g' /etc/hosts
   reboot
   ```

   After the reboot, run `pvecm updatecerts --force`. Gate: `hostname -f` prints
   `pve01.<domain>`, and `/etc/hosts` maps `192.168.50.12` to it.

## C. Join the cluster (Pedro)

1. Upgrade pve01 to the cluster's version. In pve01's web UI, open **pve01 >
   Updates > Repositories**. Disable the two enterprise repositories, then add the
   **No-Subscription** repository. Then, in pve01's shell, run
   `apt update && apt full-upgrade -y && reboot`.
   Gate: `pveversion` on pve01 matches pve03's major and minor version.

   On 2026-10-23 the upgrade took pve01 past the cluster, to 9.2.21 on kernel
   7.0.14-25. Pedro upgraded pve02 and then pve03 to match, one reboot at a time.
2. **Clear the R620's leftovers (Mac session).** A node that joins under a name the
   cluster already knows inherits whatever `/etc/pve/nodes/<name>` holds, guest
   configs included. On pve03, read:

   ```sh
   pvecm nodes
   grep -n pve01 /etc/pve/corosync.conf
   ls -la /etc/pve/nodes/
   find /etc/pve/nodes/pve01 -maxdepth 2 2>/dev/null
   grep -c pve01 /etc/pve/priv/known_hosts
   ```

   Gate: `pvecm nodes` and `corosync.conf` don't name pve01. If
   `/etc/pve/nodes/pve01` exists, archive it to `/root` on pve03 with `tar`, then
   delete it, only on Pedro's word in the Mac chat. If `known_hosts` names pve01,
   remove those lines with `ssh-keygen -f /etc/pve/priv/known_hosts -R pve01`.
3. On pve02's shell, remove the QDevice: `pvecm qdevice remove`. For the next few
   minutes the cluster has two votes and needs both. Gate: `pvecm status` shows
   `Expected votes: 2` and no `Qdevice` line.

   On 2026-10-23 a 0-vote `Qdevice` line stayed in corosync's runtime state after the
   removal, although `corosync.conf` had no device section. Restarting corosync on one
   node, waiting for `Quorate: Yes`, then on the other, cleared it.
4. On pve01's console, run `pvecm add 192.168.50.11` and type pve02's root password.
   Run it at a terminal: over `ssh` without a TTY, `pvecm` reads the next typed line
   as the password and fails with `401 authentication failure`.
5. Gate: `pvecm status` on any node shows `Nodes: 3`, `Expected votes: 3` and
   `Quorate: Yes`. The UI shows pve01 online.

## D. Bring the backup store and the GPU node back (Mac session)

Run from the PR branch until it merges, from `ansible/`. The backup store comes first,
because the nightly vzdump jobs run at 02:30 (pve02) and 02:45 (pve03) Eastern, and while
the store is disabled, every job fails. It doesn't need the driver.

1. `ansible-playbook playbooks/configure-backup-store.yml`, then
   `ansible-playbook playbooks/configure-wd-disk.yml`.
2. On pve02, run `pvesm set ollama-backups --disable 0`. On pete-pi-1, restart the
   automount: `sudo systemctl restart 'mnt-ollama\x2dbackups.automount'`.
3. Gate: `pvesm status --storage ollama-backups` shows `active` on pve02 and pve03,
   and `ls /mnt/ollama-backups/dump | wc -l` matches the survey's count (804).
4. `ansible-playbook playbooks/configure-pve01.yml -e nvidia_driver_allow_reboot=true`.
   It sets the time zone and the `.lab` domain, downloads the template with `pveam`,
   and installs the driver. It ends with "CT 246 does not exist yet". That message is
   expected at this point. Gate: the `nvidia-smi` line lists both UUIDs at
   `580.178.04`, and `dkms status` covers the running kernel.

## E. Bring up Ollama in CT 246

1. Merge the PR. Apply-on-merge creates CT 246 on pve01. Gate: the apply log shows
   `module.ollama` created, `module.pve01_host` updated in place, and nothing destroyed.
2. From `main`, run:
   - `ansible-playbook playbooks/configure-lxc-features.yml`, then `pct reboot 246` on pve01.
   - `ansible-playbook playbooks/configure-pve01.yml -e lxc_gpu_allow_restart=true`
   - `ansible-playbook playbooks/configure-ollama-246.yml`
   - `./scripts/deploy-search.sh`. It targets the `ollama` group, which holds only ollama-246.
3. Bring pve01 into the node baseline. Each play reaches pve01 through `pve_gpu`:
   - `ansible-playbook playbooks/configure-pve-firewall.yml --check --diff`, then without
     `--check`. It writes pve01's `host.fw` with `enable: 0`, which every node needs
     before the datacenter firewall filters anything.
   - `ansible-playbook playbooks/configure-journald.yml`
   - `ansible-playbook playbooks/configure-node-exporter.yml`, then `configure-metrics.yml`,
     which scrapes pve01 at `.12`.
4. Repoint the consumers: `./scripts/deploy-uptime-kuma.sh`, then
   `ansible-playbook playbooks/configure-pete-bot.yml`.
5. Gate: run the `PET-762` probe against `.246:11434`. Warm generation is at least
   60 tok/s, and `/api/ps` shows `size_vram` equal to `size` on both lanes.
   `scripts/lab-verify.sh` passes, including "models fully on GPU" and
   "cluster members".

## Rollback

Before part E passes, you can boot Ubuntu again. Power off, unplug the 128 GB drive,
and boot sda. ollama-host comes back at `.12` with Ollama, search and the export as
they were. Then run `pvecm delnode pve01` on pve03 and re-add the QDevice
(`roles/cluster-qdevice`, through `playbooks/configure-pete-pi.yml`).

## After it passes

- Delete netboot CT 239 and its code (`netboot.tf` says so). The destroy needs the repo
  variable `ALLOW_DESTROY=true`.
- Reclaim the Ubuntu root LV on sda once nobody needs the rollback.
- Give pve01's own guests a backup job. The `ollama-backups` storage is a `dir` at
  `/mnt/ollama-backups`, and pve01 serves the store from `/srv/backups`, so pve01
  needs a bind mount before the storage turns active there.
- Update the vault notes: `012-ollama-host`, a new `pve01` and `246-ollama` note,
  `hosts-inventory`, and `node-roles`.
