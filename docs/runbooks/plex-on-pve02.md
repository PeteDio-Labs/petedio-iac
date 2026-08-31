# Plex on pve02 with Quick Sync (PET-311)

**`plex-gpu` (236) on pve02 is the Plex server the house uses. `plex` (103) on
pve01 is the cold spare — installed and current, but stopped and disabled.**

To change which one serves, see [Switching which Plex serves](#switching-which-plex-serves).
That is the section to reach for when pve02 dies; the rest of this runbook is how
the thing was built and why.

| | Primary | Cold spare |
|---|---|---|
| Server | `plex-gpu` 236 | `plex` 103 |
| Node | pve02 | pve01 |
| LAN | `192.168.50.236` | `192.168.50.140` |
| Mesh | `192.168.86.236` (over VXLAN) | `192.168.86.140` (real NIC) |
| Transcoding | Intel Quick Sync | software only, no GPU |
| Service | running, enabled | stopped, **disabled** |

Measured on the same 1080p 35.7 Mbps remux, both containers 4 cores / 4 GB:
236 sustains **8.5x realtime on under 1 core**, 103 manages **4.2x while pegging
all four**. At six concurrent streams 236 still delivers 3.1x each; 103 drops to
0.77x and stutters.

**Read `docs/GOTCHAS.md` first** — the inverted bridge numbering trips every step
that touches a network interface.

## Why

pve01's two Xeon E5-2690 v2 have no integrated GPU, so every Plex transcode on
that node is software. pve02's i5-6500T has Quick Sync at `/dev/dri/renderD128`.
Plex belongs next to the GPU rather than next to the disk: a 4K remux streams at
well under a gigabit, while transcoding is what saturates a CPU.

This adds a **second** Plex. `plex` (103) stays untouched on pve01. Two Plex
servers each need their own identity — copying 103's database would give both the
same machine identifier and they would contend for one entry on plex.tv — so 236
is a fresh install scanning the same library, and 103 stays rollback-ready.

## Target state — reached

| Node | Guests |
|---|---|
| pve02 | `233` runner-233, `236` plex-gpu |
| pve01 | everything else, including `103` plex |

`236` follows the platform convention rather than the media one: every non-media
service takes a 2xx VMID whose last octet matches its IP (221 minio, 231 postgres,
233 runner, 235 plane). The 1xx block is the pve01 media stack, and this server is
not in it. 234 is skipped because it was palworld-234, and the vault keys its host
notes on VMID.

## What is done, and what is not

Done:

- `/mnt/media` + `/mnt/downloads` export from pve01 and mount on pve02 at
  identical paths. Verified from pve02: 2.6 TB, owner `100999`.
- `102 flaresolverr` has moved to pve01.
- `236` exists, is claimed, and serves the house. Four libraries mirror 103
  exactly, and the counts match: Movies 271, TV Shows 57, Music 1.
- Hardware transcoding is live and proven from an Apple TV over the mesh.
- The `.86` leg exists over VXLAN — no USB NIC was needed. See step 4.
- `plex` 103 is stopped and disabled, managed by `plex-primary.yml`.

Not done:

- `112 cloud-flare-main` is still on pve02, blocked by a snapshot — step 1. It is
  the only thing left between here and the target state, and it costs about 60
  seconds of every public hostname, so it waits for a convenient moment.

## Step 1 — move `112` off pve02

`pct migrate` refuses a container carrying a snapshot:

    can't migrate local volume 'local-lvm:vm-112-disk-0': non-migratable snapshot exists

`112` carries a six-month-old snapshot named `asdf` with no description. A
verified backup already exists, so deleting it is recoverable:

    /mnt/backups/dump/vzdump-lxc-112-2026_08_29-02_35_10.tar.zst   (164 MB)

reachable from pve01 at `/mnt/pete/backups/dump/`. To re-take it before starting:

```bash
ssh root@192.168.50.11 'vzdump 112 --storage pve02-backups --mode snapshot --compress zstd'
```

Then delete the snapshot and move the container. `112` is the Cloudflare tunnel,
so the whole public surface is down between `stop` and `start` — about 60
seconds. Do it when that is acceptable.

```bash
ssh root@192.168.50.11 'pct delsnapshot 112 asdf && pct stop 112 && pct migrate 112 pve01'
```

⚠ **Fix the bridge before starting it.** pve02's `vmbr0` is the `.50` LAN, but
pve01's `vmbr0` is the `.86` mesh — starting it unchanged strands it on the wrong
network. Keep the original `hwaddr`, since the DHCP reservation keys on it:

```bash
ssh root@192.168.50.10 'pct set 112 -net0 name=eth0,bridge=vmbr1,gw=192.168.50.1,hwaddr=BC:24:11:86:24:C2,ip=192.168.50.112/24,type=veth && pct start 112'
```

Verify the tunnel reconnected:

```bash
ssh root@192.168.50.10 'pct exec 112 -- docker ps --format "{{.Names}} {{.Status}}"'
```

## Step 2 — merge, in this order

The NFS share must exist before 236 boots and bind-mounts it.

```bash
gh pr merge 231 --repo PeteDio-Labs/petedio-iac --squash --delete-branch
```

```bash
gh pr merge 22 --repo PeteDio-Labs/petedio-media-iac --squash --delete-branch
```

Then **read the apply log**, do not just check for green. A PR run cannot show a
plan here — it runs GitHub-hosted with no Vault, LAN or state — so the
apply-on-merge log is the authoritative plan. Expect **2 to add** — the container
and its Proxmox pool membership — and nothing changed or destroyed. The seven
existing media LXCs must plan unchanged. Any change or destroy among them is a
STOP: it means the module is stripping something set out-of-band, which is how
the `startup` boot-order regression surfaced on 2026-08-31.

## Step 3 — apply the out-of-band settings, then install Plex on 236

Terraform creates 236 carrying **none** of its bind mounts, its render device, or
its `features`. Proxmox gates all of those behind a hardcoded `root@pam` check,
and the provider authenticates with an API token, so a create carrying any of
them fails:

    Permission check failed (mount point type bind is only allowed for root@pam)
    Permission check failed (configuring device passthrough is only allowed for root@pam)

Proxmox reports these **one at a time**, so removing only the block that errored
moves the failure rather than fixing it. The gated set is `features`,
`device_passthrough`, `mount_point` and `idmap`; the module lists all four in
`ignore_changes`, and that list is the catalogue.

The seven existing media LXCs escape this because they were imported — Terraform
adopted settings it never had to create. 236 is the first container built from
scratch, so it is the first to hit it.

```bash
cd ~/petedio/media-iac && ./scripts/lxc-oob-236.sh
```

That sets `mp0` `/mnt/media`, `mp1` `/mnt/downloads` (ro), `dev0`
`/dev/dri/renderD128,gid=44,mode=0660`, and `features nesting=1` in one run. It is
idempotent, and it refuses to bind a host path that is not a real mount — binding
an unmounted mount point ships an empty library while every check downstream
still passes.

Then install Plex:

```bash
cd ~/petedio/media-iac/ansible && ansible-playbook playbooks/bootstrap-plex-gpu.yml
```

The play asserts the three things that otherwise fail silently: the render node
reached the container, `plex` is in group `video` (gid 44, which is what lets it
open the device), and `/mnt/media` is mounted and non-empty from inside the
container.

⚠ **The apt repo and its key are not the obvious pair.** `repo.plex.tv` is
current; `downloads.plex.tv` is legacy and stuck on 1.42.2. They are signed by
different keys, and `PlexSign.key` — the only key Plex publishes at a well-known
URL — verifies neither on Debian 13, because its self-signature is SHA-1 and
trixie's apt rejects that from 2026-02-01. 103 is Debian 12 and accepts it, so
this looks like a Plex outage rather than a distro policy change. The role
vendors the correct key and asserts its fingerprint.

Claiming is interactive and stays manual. Open `http://192.168.50.236:32400/web`
from the LAN or the tailnet, sign in, add a library on `/mnt/media`, then enable
**Settings → Transcoder → Use hardware acceleration when available**.

## Step 4 — give pve02 a `.86` leg — DONE, over VXLAN, with no new hardware

Until this existed, 236 was reachable only from the `.50` LAN and the tailnet, and
was **invisible to every TV and phone**, because Plex clients live on the `.86`
Google mesh and `.86` does not route to `.50`.

pve02 has one physical NIC, on `.50`, and no WiFi. The proof is ARP, not ping —
pve02 pings `192.168.86.1` fine because the `.50` gateway NATs it outbound:

```bash
ssh root@192.168.50.11 'arping -c2 -I vmbr0 192.168.86.1'
```

**Beware the near-miss.** `arping 192.168.86.140` DOES answer from pve02 — but the
reply's MAC is plex 103's *`.50`* NIC answering for its `.86` address (Linux ARP
flux). Always arping the **gateway**, which exists on one segment only.

The original plan was a USB-to-Ethernet adapter. That is no longer needed.

### What was done instead

A **VXLAN** carries mesh layer-2 across the `.50` cable pve02 already has. pve01
*is* cabled to the mesh (`eno1` on its `vmbr0`), so it anchors the tunnel and
bridges it into that same mesh bridge. pve02 gets `vmbr1`, backed only by the
tunnel, and 236's second NIC lives there.

The inner Ethernet frame is never rewritten, so this is a genuine layer-2
presence: **no NAT, no proxy, no port forward, no custom access URLs**, and
native Plex client discovery. The Google router was never touched — it simply
sees one more device appear.

```bash
cd ~/petedio/iac/ansible && ansible-playbook playbooks/configure-mesh-vxlan.yml
```

The play writes and validates the interface config on both nodes and proves layer
2 with ARP. It deliberately does **not** reload networking: pve01 carries Vault,
MinIO, Plane, Authentik and the media stack, and an automatic `ifreload` there is
not worth the convenience. If a reload is genuinely needed the play says so —
run `ifreload -a` on pve01 first, then pve02.

The container's own leg is Terraform, in media-iac's `module "plex_gpu"`:

    net1_bridge   = "vmbr1"
    net1_address  = "192.168.86.236/24"
    net1_firewall = true
    net1_mtu      = 1450

⚠ **`net1_mtu = 1450` is load-bearing.** VXLAN spends 50 of the underlay's 1500
bytes on its own headers. A guest still sending 1500 produces frames that cannot
fit, and it fails in the ugly way: small packets pass, large ones vanish, so it
reads as an application bug rather than an MTU one.

⚠ **No `net1_gateway`, deliberately.** 236's default route stays on the `.50` leg
so the NFS media path from pve01 is unchanged; `.86` is a directly-connected
route. Giving both legs a gateway installs two default routes. Note this differs
from 103, which *does* carry its default on the `.86` leg.

⚠ **On pve02 the mesh is `vmbr1` and the LAN is `vmbr0`** — the opposite of plex
103 on pve01. Do not copy 103's values.

### What this costs

pve01 is now in the path for 236's mesh traffic: if pve01 is down, 236 loses its
mesh address. In practice that adds no new fragility, because 236 already reads
the whole library from pve01 over NFS, so a pve01 outage took Plex down anyway.

Jumbo frames on the `.50` underlay would remove the MTU compromise and let the
guest keep a full 1500. Both NICs report `maxmtu 9000`; whether the switch between
them agrees is untested.

## Switching which Plex serves

Exactly one Plex runs at a time. Two live servers is not redundancy — clients pick
whichever they saw last, and from the couch you cannot tell which one you are on.
The other server is stopped **and disabled**, so a container reboot cannot quietly
bring it back.

**Normal state** — `plex-gpu` serves, 103 is the spare:

```bash
cd ~/petedio/media-iac/ansible && ansible-playbook playbooks/plex-primary.yml
```

**Failover** — pve02 is down or 236 is broken, promote 103:

```bash
cd ~/petedio/media-iac/ansible && ansible-playbook playbooks/plex-primary.yml -e plex_primary=plex
```

That second command is the one to remember. It works **while pve02 is down**: the
play sets `ignore_unreachable`, because the failover case is precisely that 236
cannot be reached — and it does not need to be demoted, since it is already off
the network.

The play refuses to demote a server that is mid-stream rather than cutting the
viewer off. For a planned cutover, add `-e plex_primary_force=true`. Promotion is
never blocked; starting a server harms nobody.

**What follows you across the switch, and what does not.** The library is
read-only shared and each server keeps its own database, so flipping back and
forth is safe. Watched state lives on your Plex account rather than on either
server, so it follows you. Resume positions do **not** — they are per-server, so
a half-watched film restarts from the beginning on the other one.

Failing over to 103 means going back to software transcoding: roughly half the
throughput, all four cores pegged by a single stream, and stuttering beyond about
four concurrent viewers.

## Rollback

Nothing here ever touched 103's data, so the rollback for the Plex work is to
promote it again — one command, in
[Switching which Plex serves](#switching-which-plex-serves). The library is
read-only shared, so both servers reading it concurrently is safe.

To undo the mesh tunnel at runtime, on both nodes:

```bash
ip link del vxlan86
```

Nothing else is modified by it, and each node keeps a pre-change copy of its
interfaces file at `/etc/network/interfaces.bak-pre-mesh-vxlan`.

To undo the NFS share, unmount on pve02 and remove the `media-share` block from
pve01's `/etc/exports`. To restore `112` as it was:

```bash
ssh root@192.168.50.11 'pct restore 112 /mnt/backups/dump/vzdump-lxc-112-2026_08_29-02_35_10.tar.zst --storage local-lvm'
```

## Known cost of the target state

Once `112` sits on pve01, a pve01 outage takes down external access to a Plex
that is still running perfectly on pve02. That is the price of keeping pve02 to
just the runner and Plex, and it is worth stating rather than discovering.
