# Plex on pve02 with Quick Sync (PET-311)

Finish moving Plex onto pve02 so transcoding uses hardware. This runbook picks up
from a partly-completed state: the NFS media share is live, `102` has moved, and
both PRs are open and green.

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

## Target state

| Node | Guests |
|---|---|
| pve02 | `233` runner-233, `236` plex-gpu |
| pve01 | everything else, including `103` plex |

`236` follows the platform convention rather than the media one: every non-media
service takes a 2xx VMID whose last octet matches its IP (221 minio, 231 postgres,
233 runner, 235 plane). The 1xx block is the pve01 media stack, and this server is
not in it. 234 is skipped because it was palworld-234, and the vault keys its host
notes on VMID.

## State when this runbook was written

- `/mnt/media` + `/mnt/downloads` export from pve01 and mount on pve02 at
  identical paths. Verified from pve02: 2.6 TB, 319 movies, owner `100999`.
- `102 flaresolverr` has moved to pve01, `192.168.50.150`.
- `112 cloud-flare-main` is still on pve02, blocked by a snapshot.
- `236` is declared in Terraform but does not exist yet.

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

## Step 3 — install Plex on 236

```bash
cd ~/petedio/media-iac/ansible && ansible-playbook playbooks/bootstrap-plex-gpu.yml
```

The play asserts the three things that otherwise fail silently: the render node
reached the container, `plex` is in group `video` (gid 44, which is what lets it
open the device), and `/mnt/media` is mounted and non-empty from inside the
container.

Claiming is interactive and stays manual. Open `http://192.168.50.236:32400/web`
from the LAN or the tailnet, sign in, add a library on `/mnt/media`, then enable
**Settings → Transcoder → Use hardware acceleration when available**.

## Step 4 — give pve02 a `.86` leg (needs hardware)

Until this is done, 236 is reachable only from the `.50` LAN and the tailnet. It
is **invisible to every TV and phone**, because Plex clients live on the `.86`
Google mesh and `.86` does not route to `.50`.

pve02 has one physical NIC, on `.50`. The proof is ARP, not ping — pve02 pings
`192.168.86.1` fine because the `.50` gateway NATs it outbound:

```bash
ssh root@192.168.50.11 'arping -c2 -I vmbr0 192.168.86.1'
```

Zero replies means no L2 path, so no container there can hold a `.86` address.

**Beware the near-miss.** `arping 192.168.86.140` DOES answer from pve02 — but
the reply's MAC is `BC:24:11:B3:E2:78`, which is plex 103's *`.50`* NIC answering
for its `.86` address (Linux ARP flux). Always arping the **gateway**, which
exists on one segment only.

To fix, plug a USB-to-Ethernet adapter into pve02 and cable it either to a Nest
LAN port, or to pve01's free `eno4` after adding `eno4` to pve01's `vmbr0` — which
turns pve01's mesh bridge into a two-port switch. Then on pve02 add a bridge for
it in `/etc/network/interfaces`:

    auto vmbr1
    iface vmbr1 inet manual
        bridge-ports <new-nic>
        bridge-stp off
        bridge-fd 0
    #google mesh

Confirm `arping -I vmbr1 192.168.86.1` now answers, then add the second leg to
`module "plex_gpu"` in media-iac's `environments/media/media.tf`:

    net1_address  = "192.168.86.236/24"
    net1_gateway  = "192.168.86.1"
    net1_bridge   = "vmbr1"
    net1_firewall = true

⚠ On pve02 the mesh is `vmbr1` and the LAN is `vmbr0` — the opposite of plex 103
on pve01. Do not copy 103's values.

Note the default route: 103 carries its default gateway on the `.86` leg. Decide
deliberately which leg holds 236's, since it changes which path outbound traffic
and Plex's own relay connection take.

## Rollback

Nothing here touches 103, so the rollback for the Plex work is to keep using it
and stop 236. The library is read-only shared, so both servers reading it
concurrently is safe.

To undo the NFS share, unmount on pve02 and remove the `media-share` block from
pve01's `/etc/exports`. To restore `112` as it was:

```bash
ssh root@192.168.50.11 'pct restore 112 /mnt/backups/dump/vzdump-lxc-112-2026_08_29-02_35_10.tar.zst --storage local-lvm'
```

## Known cost of the target state

Once `112` sits on pve01, a pve01 outage takes down external access to a Plex
that is still running perfectly on pve02. That is the price of keeping pve02 to
just the runner and Plex, and it is worth stating rather than discovering.
