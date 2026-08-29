# Runbook — powering the lab down for a physical move

Covers a full cold shutdown of both Proxmox nodes and the bare-metal hosts, transport,
and a bring-up that ends with every service verified. Written for the case where the
`192.168.50.1` router travels with the gear, so every static address survives.

Expect a total outage of every service for the length of the move. Nothing here is
zero-downtime.

---

## Why the order matters

Four facts drive this runbook. Read them before you start unplugging.

**`pve01` hard-mounts NFS from `pve02`.** Three mounts (`/mnt/pete/{nexus-data,backups,shared}`),
`vers=4.2,hard`. A hard NFS mount against a dead server never times out. Shut `pve02`
down first and `pve01` hangs on unmount, indefinitely, with no console message worth
reading. **`pve01` goes down first and comes up second.**

**The cluster needs both nodes to start anything.** `pve01` + `pve02` are a 2-node
cluster with `Expected votes: 2, Quorum: 2` and no `two_node: 1` in the `quorum {}`
block. If one node does not come back, the survivor is inquorate, `/etc/pve` mounts
read-only, and `pct start` refuses for every guest. The recovery command is in
[Single node came up](#single-node-came-up) — copy it onto paper.

**Vault always boots sealed.** `configure-vault.yml` deliberately does not unseal.
The `dev.pdlab.vault-unseal` launchd agent on the Mac unseals it within about five
minutes, provided the Mac is on the LAN or the tailnet. Until that happens, `.223`
answers `503` and anything reading a secret fails.

**Registry 106 does not fail loudly.** Its blob store is an NFS bind mount from
`pve02`. If the mount is missing when the container starts, zot serves an empty
catalog and reports itself healthy. Verify it with `/v2/_catalog`, never `/v2/`.

**Every NFS export hangs off a USB drive.** `pve02`'s `/mnt/{nexus-data,backups,shared}`
are all LVs on one PV — `/dev/sda`, a WD Blue `WD10EZEX` in a JMicron JMS567 **USB 3.0
enclosure**. Those mounts now carry `nofail,x-systemd.device-timeout=30`,
so a slow drive gets 30 seconds to appear and a missing one no longer wedges the boot.
Before that, a drive that failed to enumerate took out `local-fs.target`, dropped `pve02`
to an emergency shell, cost quorum, and stopped `pve01` from starting anything — a jostled
USB cable presenting as a totally dead lab.

**The cost of the fix is that the failure is now silent.** `pve02` boots, keeps quorum, and
`nfs-server` exports the empty mount points off the rootfs — so the registry serves an empty
catalog and backups write to the wrong disk. Verify the mounts, never assume them. See
[The USB drive under everything](#the-usb-drive-under-everything).

Boot order is set on the node with `pct set --startup` and is listed in
[Boot order](#boot-order). `startup` sits in `ignore_changes` in
`modules/proxmox-lxc/main.tf`, so an apply-on-merge cannot strip it.

---

## T-minus 2 days

### Get the Vault unseal key off the Mac

The unseal key and root token exist in exactly one place: the `login.keychain-db`
on the MacBook, as `vault-unseal-key` and `vault-root-token` under account
`vault-223`. That machine is travelling. If it is lost or its drive dies, Vault is
unrecoverable, and it holds the CI credentials, the database passwords, and the
Cloudflare tunnel token.

Read both values and put them somewhere that is not the Mac — a password manager
that syncs off-device, or paper in a different bag from the laptop:

```bash
security find-generic-password -a vault-223 -s vault-unseal-key -w
```

```bash
security find-generic-password -a vault-223 -s vault-root-token -w
```

### Re-authenticate the Mac on the tailnet

The MacBook's tailnet node key expires **2026-08-29**. The subnet router
`tailscale-244` is good until 2026-12-23, so the LAN stays advertised — but a lapsed
key on the Mac costs you remote reach exactly when the gear is in a truck. Re-auth
before you pack, and disable key expiry on `tailscale-244` in the Tailscale admin
console while you are there. Infrastructure nodes should not carry an expiry.

### Freeze CI

A merge to `main` in `petedio-iac` or `petedio-media-iac` triggers `plan` + `apply`
on the self-hosted runner. Against a half-booted cluster that is a bad apply against
a good state file. Merge nothing for the duration of the move. The runners go offline
with the lab and re-register themselves on the way back — no action needed there.

### Take backups off-site

Every backup target currently travels in the same truck as its source:
`/mnt/backups` is on `pve02`'s single HDD, Vault snapshots live in MinIO on `pve01`,
and Uptime Kuma's history is on the Pi's SD card. For a few days in transit, get a
copy onto something that is not going in the truck.

```bash
mkdir -p ~/lab-move-backup && ssh -i ~/.ssh/id_ed25519_ansible root@192.168.50.231 \
  'su - postgres -c pg_dumpall | gzip' > ~/lab-move-backup/postgres-all.sql.gz
```

Vault raft snapshot — needs `VAULT_ADDR`, `VAULT_CACERT` and the root token in your
environment, per `docs/runbooks/vault-resilience.md`:

```bash
vault operator raft snapshot save ~/lab-move-backup/vault-premove.snap
```

Uptime Kuma's database, so the fault-study baseline survives an SD-card failure:

```bash
ssh -i ~/.ssh/id_ed25519_pete_pi_2 pedro@192.168.50.4 \
  'sudo sqlite3 /opt/uptime-kuma/data/kuma.db ".backup /tmp/kuma-premove.db"' \
  && scp -i ~/.ssh/id_ed25519_pete_pi_2 pedro@192.168.50.4:/tmp/kuma-premove.db ~/lab-move-backup/
```

Guest configs for both nodes are already saved at `/root/pre-move-backup/lxc/` on each
node, alongside `fstab` and `corosync.conf` copies. Pull those to the Mac too.

### The export drive: move it inside the chassis

`pve02` is the file server for the whole `/24`, and the disk it serves from is external.
`/dev/sda` is a WD Blue `WD10EZEX` behind a JMicron JMS567 USB 3.0 bridge, and it is the
**sole physical volume** of the `network-storage` volume group. All three exports live on
it: the zot blob store, every backup, and `/mnt/shared`.

Its SMART health is `PASSED` with zero reallocated and zero pending sectors — but it has
**23,360 power-on hours** (about 2.7 years) and **12,442 start/stop cycles**. It is a
well-used drive, and the enclosure then adds failure modes a bare drive does not have: a
cable working loose under vibration, a bus reset under load, or its own power supply.

**The fix is better than mitigation — put the drive inside the machine.** `pve02` is a Dell
OptiPlex 7040 with four SATA ports at the chipset and **no SATA drives attached**; its only
storage today is the NVMe and this enclosure. The `WD10EZEX` is a standard 3.5" drive, so it
can come out of the enclosure and onto a SATA port. LVM finds the same volume group on the
same disk whatever the transport, so there is no data migration and no rebuild.

Check two things before move day: that the chassis has a free 3.5" bay — an SFF 7040 does, a
Micro does not — and that you have a SATA data cable and a spare power lead.

This is the best piece of move preparation available, because it does not reduce the risk of
the most transport-fragile component in the estate. It removes the component.

**Either way, copy the contents off first. It is only about 12 GB:**

```bash
mkdir -p ~/lab-move-backup/pve02-exports
rsync -a --info=progress2 \
  root@192.168.50.11:/mnt/{nexus-data,backups,shared}/ \
  ~/lab-move-backup/pve02-exports/
```

If you cannot move it inside before the move, **transport it separately** — unplugged and
padded, in a bag rather than dangling off the back of the chassis. Reconnect it before you
power `pve02` on, not after.

> The zot blob store is the one part that is cheaply rebuildable: every entry in it is a
> pull-through cache of Docker Hub or lscr.io, so a lost blob store re-fills on demand. The
> backups and `/mnt/shared` are not.

### Photograph the physical layout

Before anything comes out of the rack: photograph the back of both nodes, every cable
and its port, and the drive bays. `pve01`'s disks sit behind a **PERC H710** hardware
RAID controller — the array config lives on the controller and on the disks, so
**label every drive with its bay number and put them back in the same slots**. A
reordered array is a foreign-config import at best.

There is **no UPS** on either node (`nut` and `apcupsd` are both inactive). Every
shutdown from here is a manual, deliberate one, and any power blip at the new place
is a hard stop. Worth buying one before the gear lands.

---

## Shutdown

Run these in order. Do not parallelize.

**1. Drain CI.** Confirm no job is running, then stop both runners:

```bash
ssh -i ~/.ssh/id_ed25519_proxmox_pedro root@192.168.50.10 'pct stop 232' && \
ssh -i ~/.ssh/id_ed25519_proxmox_pedro root@192.168.50.11 'pct stop 233'
```

**2. Shut down `pve01`.** The `down` delays set on each guest let Postgres, Authentik
and Plane close cleanly; `pve-guests` stops them in reverse startup order:

```bash
ssh -i ~/.ssh/id_ed25519_proxmox_pedro root@192.168.50.10 'shutdown -h now'
```

Wait for it to stop answering ping. Do not move to the next step early — this is the
step that releases the NFS mounts.

```bash
until ! ping -c1 -W1000 192.168.50.10 >/dev/null 2>&1; do sleep 5; done; echo "pve01 down"
```

**3. Shut down `pve02`**, only once `pve01` is confirmed down:

```bash
ssh -i ~/.ssh/id_ed25519_proxmox_pedro root@192.168.50.11 'shutdown -h now'
```

**4. Shut down the bare-metal hosts.** The Pi is last so it records the cluster going
down, and its SD card needs the clean stop:

```bash
ssh ollama-host 'sudo shutdown -h now'                                  # .12, logs in as pedro
ssh -i ~/.ssh/id_ed25519_ansible root@192.168.86.234 'shutdown -h now'  # palworld / mission-control
```

Then pull Uptime Kuma's database one last time, so the recording of the cluster going down
survives off the SD card. Its six-hourly copy goes to `/mnt/pve02-backups`, which lives on
`pve02` — already off by this point, so this pull is the only fresh copy.

```bash
ssh -i ~/.ssh/id_ed25519_pete_pi_2 pedro@192.168.50.4 \
  'sudo sqlite3 /opt/uptime-kuma/data/kuma.db ".backup /tmp/kuma-final.db"' \
  && scp -i ~/.ssh/id_ed25519_pete_pi_2 pedro@192.168.50.4:/tmp/kuma-final.db ~/lab-move-backup/
```

Only then power the Pi down:

```bash
ssh -i ~/.ssh/id_ed25519_pete_pi_2 pedro@192.168.50.4 'sudo shutdown -h now'
```

**5. Power off the router and switches last.** Everything above needs the gateway to
reach anything.

---

## Bring-up

Power on in this order, waiting for each step to finish. The whole sequence takes
about 15 minutes.

**1. Router and switches.** `192.168.50.1` is both the default gateway and the
primary DNS resolver for every host. Nothing works before it does. Confirm it hands
out its own address and reaches the internet before continuing.

**2. Pete-Pi.** Bring the instrument up before the things it measures. Every monitor
starts DOWN, which is correct — the cluster is still off — and each goes green as you work
down this list. That makes Uptime Kuma a live bring-up dashboard instead of an afterthought.
Confirm both legs, because the `.86` leg is the only route to Plex:

```bash
ssh -i ~/.ssh/id_ed25519_pete_pi_2 pedro@192.168.50.4 \
  'ip -br addr show | grep -Ev "^lo|docker|veth|br-"'
```

**3. `pve02`.** If the export drive is still external, reconnect it **before** powering the
node on. It is the NFS server, and `pve01` mounts from it at boot. Confirm the disk
enumerated and the volume group assembled before you look at anything else — the `TRAN`
column tells you whether you are on SATA now or still on USB:

```bash
ssh -i ~/.ssh/id_ed25519_proxmox_pedro root@192.168.50.11 \
  'lsblk -o NAME,SIZE,TRAN | grep -A3 sda; vgs network-storage'
```

Then wait for the exports:

```bash
ssh -i ~/.ssh/id_ed25519_proxmox_pedro root@192.168.50.11 \
  'systemctl is-active nfs-server && exportfs -v'
```

All three exports (`/mnt/nexus-data`, `/mnt/backups`, `/mnt/shared`) must be listed
before you power on `pve01`.

**4. `pve01`.** Guests start themselves in the configured order — about 2.5 minutes
from node boot to the last media container. Nothing to run by hand.

**5. `ollama-host`, then the Palworld laptop.** Nothing in the cluster depends on either,
so they come last. Both need checks of their own — see
[The three hosts no Terraform owns](#the-three-hosts-no-terraform-owns).

**6. Unseal Vault** if the launchd agent has not already. It fires within five
minutes of the Mac reaching `.223`; check before doing it manually:

```bash
curl -s --cacert environments/homelab/vault-ca.crt \
  https://192.168.50.223:8200/v1/sys/health | python3 -m json.tool | grep sealed
```

---

## Verification — the definition of "100% up"

Work down the list. Every one of these should pass before you call the move done. Run
them from the repo root — two use `environments/homelab/vault-ca.crt` as a relative path.

**Cluster is quorate and every guest is running.** 18 on `pve01`, 3 on `pve02`:

```bash
ssh -i ~/.ssh/id_ed25519_proxmox_pedro root@192.168.50.10 \
  'pvecm status | grep -E "Quorate|Total votes"; pct list | grep -c running'
```

**The NFS mounts came back**, and the registry can actually reach its blob store.
`_catalog` touches the storage layer; `/v2/` answers from memory and stays green
through an NFS outage:

```bash
ssh -i ~/.ssh/id_ed25519_proxmox_pedro root@192.168.50.10 'df -h /mnt/pete/nexus-data | tail -1'
```

```bash
curl -sk https://192.168.50.111/v2/_catalog
```

**Vault is unsealed.** `/v1/sys/health` returns 200 unsealed, 503 sealed:

```bash
curl -s -o /dev/null -w '%{http_code}\n' --cacert environments/homelab/vault-ca.crt \
  https://192.168.50.223:8200/v1/sys/health
```

**Both MinIOs answer.** `.221` holds Terraform state, `.245` holds app buckets:

```bash
curl -s -o /dev/null -w '221:%{http_code}\n' http://192.168.50.221:9000/minio/health/live && \
curl -s -o /dev/null -w '245:%{http_code}\n' http://192.168.50.245:9000/minio/health/ready
```

**Terraform state is readable and the cluster matches it.** An empty plan here is the
strongest single signal that the lab came back as it left:

```bash
cd environments/homelab && terraform init && terraform plan
```

**The tailnet still routes the LAN.** Check forwarding first, not Tailscale — a
subnet router with `ip_forward=0` looks healthy from every other angle:

```bash
ssh -i ~/.ssh/id_ed25519_ansible root@192.168.50.244 'sysctl net.ipv4.ip_forward'
```

**Both ollama GPUs came back, and both lanes answer.** Kuma watches `:11434` only, so a
green ollama monitor does not prove the 1660 SUPER survived the trip:

```bash
ssh ollama-host 'nvidia-smi -L; ss -lntp | grep -E "11434|11435"'
```

**Pete-Pi has both legs and Kuma is running.** A one-legged Pi produces a false DOWN on
the Plex monitor:

```bash
ssh -i ~/.ssh/id_ed25519_pete_pi_2 pedro@192.168.50.4 \
  'sudo docker inspect uptime-kuma --format "{{.State.Status}}"; ip -br addr show | grep -Ev "^lo|docker|veth|br-"'
```

**Uptime Kuma is all green.** The real acceptance test — 14 monitors covering both ends of
every cross-host dependency: http://192.168.50.4:3001. Check the two checks above first,
though: Kuma is the instrument, so it cannot be the thing that tells you the instrument
is healthy.

**Public URLs resolve through the tunnel.** `cloudflared` on 112 is outbound-only and
token-managed, so it reconnects on its own with no port forward and no new public IP
to register: `auth`, `seer`, `co-latro`, `admin`, `cv` and `fast` on `pdlab.dev`.

**Postgres has its databases.** Expect `admin`, `plane`, `poker` and `waterfast`:

```bash
ssh -i ~/.ssh/id_ed25519_ansible root@192.168.50.231 'su - postgres -c "psql -lt" | cut -d"|" -f1'
```

---

## The three hosts no Terraform owns

Pete-Pi, `ollama-host` and the Palworld laptop sit outside the cluster and outside IaC.
No `onboot` flag starts them, no `startup` order sequences them, and no Terraform plan
will notice if one fails to come back. They need checking by hand.

### Pete-Pi `.4` — the instrument

It comes back on its own: Docker is enabled at boot and the `uptime-kuma` container is
`restart=unless-stopped`. Two things still need eyes on them.

**Both legs are load-bearing.** `eth0` at `192.168.50.4` (default route, metric 100)
reaches the cluster; `wlan0` at `192.168.86.46` is the only route to Plex on
`192.168.86.140`. A Pi that comes up with one leg reports a false DOWN on the Plex
monitor and you will chase Plex instead of the Pi.

**The SD card is the only disk**, holding roughly 343,000 heartbeats. A six-hourly timer
copies the database to `/mnt/pve02-backups` — an automount with `soft,timeo=50`, so a
dead `pve02` makes the backup skip and retry rather than wedge the instrument. That also
means no backup runs at all while `pve02` is packed, which is why the shutdown sequence
pulls a final copy to the Mac.

```bash
ssh -i ~/.ssh/id_ed25519_pete_pi_2 pedro@192.168.50.4 \
  'sudo docker inspect uptime-kuma --format "{{.State.Status}}"; ip -br addr show | grep -Ev "^lo|docker|veth|br-"'
```

### ollama-host `.12` — two GPUs, and Kuma only watches one of them

Log in as `pedro` (`ssh ollama-host`), **not** as root with the ansible key — that key is
not authorized here.

Two services run, both enabled at boot: `ollama.service` on `:11434` and
`ollama-1660s.service` on `:11435`, the second pinned to the GTX 1660 SUPER. **Kuma
monitors `:11434` only.**

That is the silent failure to watch for. If the 1660 SUPER does not reseat during the
move, `ollama-1660s` fails while `:11434` stays green on the 3060 Ti — and Kuma reports
ollama healthy with 6 GB of VRAM missing. Same shape as zot serving an empty catalog.
A heavy card in a PCIe slot is one of the likeliest things on this list to shift in
transit.

```bash
ssh ollama-host 'nvidia-smi -L; ss -lntp | grep -E "11434|11435"'
```

Both cards must be listed, and both ports must answer. Leave `/etc/netplan/` alone: the
static address lives in `99-ollama-static.yaml`, and this box has a documented history of
`netplan apply` silently no-opping when a manual config fights cloud-init.

### Palworld / `mission-control` `.86.234` — the laptop

An **HP Spectre x360 16-f0xxx** on the `.86` segment only, so it needs the house network
up rather than the `.50` one. Root over `id_ed25519_ansible`.

**It is the most independent stack you own.** It runs its own `cloudflared` connector for
`palworld.pdlab.dev`, separate from the tunnel on LXC 112, and needs no cluster, no Vault
at runtime, and no `pve02`. Give it power and internet and it comes back on its own. It is
the one service that survives a total cluster failure.

**The game does not auto-start, and that is deliberate.** `palworld.service` is
`disabled`; `cloudflared` and `palworld-panel` are `enabled`. After the move the panel
returns by itself and you start the game **from the panel** (PET-303). Do not go hunting
for a broken server — a stopped Palworld on a running panel is the designed state.

**Lid close is already safe.** `sleep.target`, `suspend.target` and `hibernate.target` are
all masked, so closing the lid cannot suspend the machine even though `logind.conf` is at
its defaults. Nothing to do here; just do not unmask them.

**It is the only machine in the estate with a built-in UPS**, which matters because nothing
else has one. That is a genuine asset — and the reason to look after the battery.

**Check the battery before you move it.** It reports 67.29 Wh against an 83 Wh design
capacity — about **81% of health** — with a cycle count of **0**, meaning it has sat at
full charge on AC for its entire life. That float-charge pattern is what degrades and
eventually swells a cell, and a 2-in-1 chassis is thin enough that a swollen battery warps
the case and pushes on the trackpad and screen.

Two things follow. Inspect the chassis for any bulge or flex before packing it, and look
in the HP firmware for a battery-care or charge-limit setting — there is no kernel-level
`charge_control_end_threshold` on this machine, so capping the charge is a BIOS-only
option.

**Transport it as a laptop, not as a server.** It is the one machine here designed to be
carried. Shut it down, close it, put it in a padded bag. It needs no cable labelling and
no drive handling.

---

## Rehearse the restart before you pack

The boot order in this runbook has never been exercised. It was set on already-running
containers, so nothing has yet proven that the sequence, the delays, or the `nofail`
mounts behave on a real cold start.

Two hosts also carry long uptimes: `ollama-host` at 11 days and `mission-control` at
**12 weeks**. A machine that has not rebooted in three months can be holding runtime
state that was never persisted to disk — which is exactly how `tailscale-244`'s
`ip_forward` regression stayed hidden until a reboot exposed it.

A full rehearsal costs one outage at home, where a surprise is cheap and every tool you
own is unpacked. Discovering the same problem at the new place, with the truck gone,
costs considerably more. Run the shutdown and bring-up sequences end to end before
moving day.

---

## Out-of-band access: iDRAC on pve01

**This is the single most useful thing in this document.** pve01 outputs VGA only, and there
is no VGA monitor here. When it fails to boot, iDRAC is the only way to see the screen.

| | |
|---|---|
| Address | `192.168.0.120` — the **factory default static**, not DHCP |
| MAC | `f8:bc:12:37:ef:c6` |
| Licence | **iDRAC7 Enterprise** — includes Virtual Console (full remote KVM) |
| Port | Dedicated iDRAC NIC, cabled to the `.86` segment |

**It is invisible to every normal scan.** It sits on `192.168.0.0/24`, answers no NDP
multicast, and appears on neither `.50` nor `.86`. Sweeping those two subnets finds nothing.
To reach it, alias your Mac onto its subnet:

```bash
sudo ifconfig en0 alias 192.168.0.240 255.255.255.0
```

Then open `https://192.168.0.120/start.html`. Remove the alias with `sudo ifconfig en0
-alias 192.168.0.240`; it does not survive a reboot or a wifi reconnect.

Set **Plug-in Type: HTML5** under Virtual Console before launching, or the Launch link
downloads a Java `.jnlp` that will not run.

> **Worth fixing:** give iDRAC a DHCP reservation on a sane subnet so this stops needing an
> alias, and change its password if it is still the `root` / `calvin` default — it is a full
> remote-console interface sharing a network with every phone and TV in the house.

### The intrusion switch will stop the machine booting

**With the chassis cover off, the R620 will not complete power-on.** It reports
`Server Status: ON` while drawing **0 Watts**, and the front LEDs look normal. Every power
button press and every iDRAC power command appears to succeed and does nothing.

It also generates **spurious drive faults** — seven simultaneous "Fault detected on drive N
in disk drive bay 1" entries, plus `RAC0501: There are no physical disks to be displayed`.
None of those are real. The SEL records the actual cause plainly:

```
The chassis is open while the power is on.
```

Read the SEL before believing any storage fault on this machine, and check the cover first.

### A LOM that answers ping does not mean the host is running

pve01's NICs stay powered from the standby rail via NC-SI, so both bridges answer **IPv6
link-local** even with the host completely off. During the 2026-08-28 outage this looked
exactly like "the machine is booted but its services failed", and it was not — the server
was drawing zero watts the entire time.

**The test that distinguishes them:** a running host answers TCP. If ICMPv6 replies but
ports 22 and 8006 are both silent on both bridges, the host is not running — go to iDRAC,
not to the network.

### Diagnostic order for pve01

Do these in order. Tonight's outage took hours because this was done backwards.

1. **iDRAC first** — `Server Status`, `Present Reading` watts, and the SEL. Watts is the
   honest signal; `Server Status` can say ON when nothing is powered.
2. **Virtual Console** — read the actual screen.
3. Only then the network, cables and switch.

---

## The two networks are nested, not isolated

`.50` sits **behind** `.86`: the `192.168.50.1` router has its WAN on the `.86` segment and
NATs outbound. Verified 2026-08-28:

- **`.50` → `.86` works.** pve02, with no `.86` leg, reached `192.168.86.140:32400` and
  `192.168.86.234:22`.
- **`.86` → `.50` does not.** mission-control, which is `.86`-only, could reach none of
  pve01:8006, Pete-Pi:3001 or pve02:2049.

Two consequences.

**The vault is wrong about Pete-Pi.** `004-pete-pi.md` says the `.86` leg is *"the only path
to plex on 192.168.86.140"*, and the Uptime Kuma monitor design cites it. That is false —
`.50` reaches `.86` fine. The `wlan0` leg is not needed for that monitor.

**Pete-Pi is your way in when the tailnet is down.** `tailscale-244` is a guest on pve01, so
it dies with that host, and a Mac on `.86` then has no route into `.50`. Pete-Pi is
dual-homed and reachable from `.86`, which makes it the jump host:

```bash
ssh -A -i ~/.ssh/id_ed25519_pete_pi_2 pedro@192.168.86.46
```

Use `-A` so the Proxmox key stays on your Mac rather than being copied to the Pi.

---

## When it goes wrong

### pve01 powers on but never reaches the network

The 2026-08-28 outage. Symptoms: no IPv4, no TCP on any port, but both bridges answer IPv6
link-local, and the front LEDs look fine. Work it in this order.

1. **iDRAC → Power/Thermal.** If `Present Reading` is **0 Watts**, the machine is not
   running whatever `Server Status` claims. Check the chassis cover — see
   [the intrusion switch](#the-intrusion-switch-will-stop-the-machine-booting).
2. **iDRAC → Logs.** The SEL names the real fault. Ignore drive faults until you have
   confirmed the cover is on; an open chassis fabricates them.
3. **Virtual Console.** `Boot Failed: proxmox / No boot device available` means POST is
   fine and the PERC is not presenting the array.
4. **iDRAC → Storage.** `RAC0501` with 0 physical and 0 virtual disks, plus *"no
   out-of-band capable controllers detected"*, means iDRAC cannot see the PERC at all.
5. **Ctrl+R at POST** for the controller's own view. Virtual disks showing as **foreign**
   is an import and recoverable. No drives at all is the card or the backplane.

> **Never** initialize, clear or recreate an array in the PERC BIOS. That destroys
> `/mnt/media` and every guest on pve01.

### Single node came up

The other node is dead and nothing will start. `/etc/pve` is read-only, so you cannot
fix this by editing a file. Force quorum from the surviving node:

```bash
pvecm expected 1
```

`/etc/pve` becomes writable and `pct start` works again. This does not persist across
a reboot — it is a bridge to get services up while you deal with the dead node. Do not
run it while the other node is alive but unreachable; two nodes each believing they
have quorum is how you split-brain a cluster.

### `pve01` boots but `/mnt/pete/*` is empty

`pve02` was not ready in time. The mounts now carry `nofail`, so `pve01` boots instead
of hanging — the cost is that a missing mount is silent. Fix it once `pve02` is up:

```bash
ssh -i ~/.ssh/id_ed25519_proxmox_pedro root@192.168.50.10 'mount -a && pct restart 106'
```

The restart is required. The bind mount is established at container start, so 106 holds
an empty directory until it is restarted.

### Vault stays sealed

The launchd agent needs the Mac to reach `.223`. If it has not fired within five
minutes, check the agent and then unseal by hand with the key you escrowed.

```bash
launchctl list | grep vault-unseal
```

`vault operator unseal` takes a positional key and has **no stdin convention** —
piping into it passes the literal `-` and fails with a message that looks like a bad
key. Use the HTTP API, which is what `pet-secrets` does.

### pve02 will not boot, or its exports are empty

Almost always the USB drive. `/dev/sda` is the sole PV of the `network-storage` VG.
Since the mounts gained `nofail`, the node **will** boot without it — so the symptom is no
longer an emergency console but an empty `/mnt/nexus-data` and a registry serving nothing.
Check the disk first:

```bash
lsblk -o NAME,SIZE,TRAN          # is /dev/sda there at all, and on 'usb'?
vgs; vgchange -ay network-storage
mount -a && systemctl restart nfs-server && exportfs -v
```

If the drive is absent, reseat the USB cable and try a different port before assuming the
disk is dead — a bridge chip that failed to enumerate looks identical to a dead drive. Once
`pve02` exports again, `pve01`'s registry still needs a nudge, because CT106's bind mount is
established at container start:

```bash
ssh -i ~/.ssh/id_ed25519_proxmox_pedro root@192.168.50.10 'mount -a && pct restart 106'
```

**What `nofail` bought, and what it cost.** Before it, a missing drive meant no `pve02`
boot, no quorum, and `pve01` starting nothing — a 12 GB USB disk presenting as a totally
dead lab, with `pvecm status` sending you to corosync instead of to a cable. Now the cluster
comes up healthy and only the exports are gone. That is the better failure, but it is the
quiet one: nothing alerts, and Uptime Kuma's zot monitor is the thing most likely to catch
it, because its `/v2/_catalog` probe touches the storage layer.

### A disk did not survive the trip

A cold start after transport is when a marginal drive fails. `pve01` carries 2.6 T of
media on `sdb` behind the PERC. Check the controller's view before assuming a
filesystem problem, and do not let the array rebuild onto a second questionable disk.

```bash
ssh -i ~/.ssh/id_ed25519_proxmox_pedro root@192.168.50.10 'lsblk; vgs; pvs'
```

---

## Boot order

Set with `pct set <vmid> --startup order=N,up=S,down=S`. `order` ascends; `up` is the
delay after that guest starts before the next one does; `down` is how long its
shutdown may take. Guests sharing an order start by ascending VMID.

### pve01

| Order | VMID | Host | Startup | Why here |
|---|---|---|---|---|
| 1 | 244 | tailscale-244 | `up=10` | Remote access first — if the rest fails you still need in |
| 2 | 221 | minio-221 | `up=5,down=30` | Terraform state backend |
| 2 | 223 | vault-223 | `up=15,down=30` | Root of trust; comes up sealed |
| 3 | 231 | postgres-rds-231 | `up=25,down=60` | Before anything holding a connection to it |
| 4 | 106 | nexus-registry | `up=10,down=30` | Needs the NFS blob store from pve02 |
| 4 | 119 | authentik | `up=25,down=60` | SSO — every downstream login depends on it |
| 4 | 245 | minio-data-245 | `up=5,down=30` | App buckets |
| 5 | 230 | poker-api-230 | `up=5,down=30` | Apps — all need 231 and 119 |
| 5 | 232 | runner-232 | `up=0,down=30` | |
| 5 | 235 | plane-235 | `up=5,down=60` | |
| 5 | 241 | openfaas-241 | `up=5,down=30` | |
| 6 | 110 | qbittorrent-vpn | `up=20,down=30` | Gluetun needs the VPN up before its consumers |
| 7 | 100 | lidarr | `up=0,down=15` | Media stack last |
| 7 | 101 | seerr | `up=0,down=15` | |
| 7 | 103 | plex | `up=0,down=15` | |
| 7 | 104 | sonarr | `up=0,down=15` | |
| 7 | 105 | radarr | `up=0,down=15` | |
| 7 | 109 | prowlarr | `up=0,down=15` | |

### pve02

| Order | VMID | Host | Startup |
|---|---|---|---|
| 1 | 112 | cloud-flare-main | `up=5,down=30` |
| 2 | 102 | flaresolverr | `up=0,down=15` |
| 2 | 233 | runner-233 | `up=0,down=30` |

---

## After you land

None of this belongs in moving week. Do it once the lab is up, verified, and you have time
to debug a surprise. Ordered by value against effort.

### 1. A qdevice on ollama-host

The highest-value change available, and it is one command. `corosync-qnetd` is an
arbitrator daemon, not a cluster member: it hosts no guests and holds no storage.

```bash
pvecm qdevice setup 192.168.50.12
```

That makes three votes across two nodes, so quorum becomes 2 and **either node can die
while the survivor keeps running**. It deletes the failure mode this runbook opens with,
and it retires the `pvecm expected 1` recovery step.

It also beats the two alternatives. `two_node: 1` + `wait_for_all: 0` works by disabling
the safety check rather than by arbitrating, and it needs a live `config_version` bump.
Removing `pve02` from the cluster makes `pve01` permanently quorate but does nothing if
`pve01` is the node that dies.

**Not Pete-Pi.** It is deliberately outside the cluster so it can keep recording while a
node is the thing being broken. Making it the arbitrator couples the instrument to what it
measures. `ollama-host` has no such conflict.

### 2. flaresolverr to pve01, with a static address

Prowlarr is its only consumer and Prowlarr is on `pve01`, so every Cloudflare challenge
currently crosses nodes for no reason. It is stateless with no bind mounts.

It is also **the only guest on DHCP**, holding `.150` today. If that lease ever moves,
your indexers quietly return fewer results with no alert. Give it static `.102` on the way
over and both problems close in one migration.

### 3. runner-233's rootfs onto the NVMe

Its rootfs is a raw file on `pve02-shared`, which is `/mnt/shared` on the USB-attached
drive. Move it to `local-lvm`, which is NVMe-backed.

### 4. Storage: give each drive one job

The two MinIOs hold **629 MB between them** — 104 MB on `minio-221` and 525 MB on
`minio-data-245`, both sitting at single-digit percentages of their rootfs. Object storage
needs no dedicated drive here. Note also that MinIO advises against network filesystems as
a backend, so an NFS-backed MinIO would be the wrong shape regardless of capacity.

Meanwhile `/mnt/media` is at **84% with 501 GB free and `media-vg` at `VFree: 0`** — the
one genuine storage constraint in the estate, and unfixable from existing space.

| Drive | Job |
|---|---|
| `ollama-host` ~800 G unallocated (SMR) | **Backups.** Off-machine, sequential writes — SMR is well suited |
| `pve02` WD 931 G (7200 CMR, internal) | zot blobs, plus **media overflow** |
| `pve01` `sdb3-storage` SSD | Guest rootfs, both MinIOs included |

Extend `ollama-host`'s root LV first — it is 76% full on a 100 G volume with ~800 G
unallocated beside it in the same VG. That box needs a password for `sudo`, unlike Pete-Pi.

Once backups move to `ollama-host`, the WD frees its 300 G `backups` LV and most of
`shared`, leaving roughly 700 GB. You cannot extend `media-vg` across a network, but Plex
and the \*arrs all support multiple root folders — export the free space and add it as a
second library path.

### 5. The registry onto pve02

`106` is the only guest whose storage lives on the other node: it binds
`/mnt/pete/nexus-data`, which is NFS from `pve02`. Running it there makes the blob store
local, deletes the estate's nastiest cross-node edge, and removes one of `pve01`'s two
boot-critical NFS mounts. Put its rootfs on `local-lvm`, not `pve02-shared`.

**It conflicts with PET-300.** That cross-node dependency is the deliberate subject of the
fault-injection study — Uptime Kuma watches zot and the NFS export as separate monitors
precisely because cause and symptom sit on different hosts. Moving `106` deletes the
experiment. Decide which you want rather than drifting into it.

### 6. Renumber the media block

`VMID == last IP octet` holds for all fourteen guests from 112 up. It breaks for the nine
legacy ones: `100→.14`, `101→.33`, `102→dhcp`, `104→.15`, `105→.16`, `106→.111`,
`109→.20`, `110→.21`, and `103` on the `.86` network.

**Renumber the IPs, never the VMIDs.** The vault, the lab graph and `notes-svc` all key on
VMID — `agent-loop-242` → `resume-242` is the proof that the name is disposable and the
number is not. Change a VMID and you orphan every note about that host.

Budget it as an application migration rather than a network change. The media stack
references itself by raw IP inside app databases — Sonarr's download client points at
`192.168.50.21` — and Uptime Kuma's fourteen monitors are deliberately raw IPs too.

### 7. AC Power Recovery, on both nodes

Neither node came back on its own after the 2026-08-25 power cut. Set **AC Power
Recovery** to *Last State* — R620 under System Setup &rarr; System Security, OptiPlex under
Power Management. Do it through iDRAC's virtual console on pve01 rather than hunting a VGA
monitor.

### 8. A UPS

No node has one; `nut` and `apcupsd` are both inactive. The Palworld laptop is the only
machine in the estate with a battery.

---

## Considered and rejected

Recorded so they do not get re-proposed.

**tailscale-244 to pve02.** It would put both remote-access paths on one node. `244` is
the subnet router for the whole `/24`, so losing `pve02` would cost the tunnel, the tailnet
and any way to reach the lab to diagnose it. Keep the two paths on different nodes.

**vault-223 to pve02.** Every Vault consumer is on `pve01`, so this puts every secret read
on the wire. Vault's audit device is fail-closed, and `pve02`'s only non-NVMe guest storage
is the USB drive. The root of trust belongs beside its consumers.

**The media stack to pve02.** Six guests bind `/mnt/media` and `/mnt/downloads` on
`pve01`'s array. Moving them means moving 2.6 TB onto a node with 931 GB, 4 threads and
15 GiB. Plex additionally needs `.86`, and `pve02` has one NIC and no PCIe slot for another.

**Plex to pve02 for Quick Sync.** `pve01` cannot hardware transcode — its only graphics
device is a Matrox G200eR2 BMC chip — and `pve02` has an unused HD 530. But the logs show
**zero** transcoder launches and no transcode cache artifacts: your clients direct-play
everything, including 4K Dolby Vision. The benefit today is zero, against a new cross-node
NFS export and a USB NIC. If that ever changes, put a low-profile card in `pve01` instead —
it is a PowerEdge R620 with three free PCIe 3 slots.

**ollama-host as pve03.** It runs Ubuntu 24.04, so Proxmox means a full rebuild. Its 16 GiB
is already the binding constraint on its real job, and its ST1000LM035 is a 5400 RPM SMR
laptop drive — poor storage for guest rootfs. Take the qdevice instead and leave the RAM
and both GPUs pointed at Ollama.

**A dedicated drive for MinIO.** They use 629 MB.
