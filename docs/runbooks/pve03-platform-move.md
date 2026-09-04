# Runbook — moving guests between nodes

How the platform tier moved from `pve02` to `pve03` on 2026-09-04 (PET-334), and how
to move anything else. Twelve containers, 36 minutes, no data loss and no rebuild.

The split it established: **pve02 is the media node** — the disks, Plex (236) and
qBittorrent (110), nothing else. **pve03 is the platform node** — everything else.

---

## Terraform cannot move a container

This is the fact the whole procedure is built around. Both `node_name` and
`datastore_id` force **replacement** on the bpg provider:

```
# module.poker_api.proxmox_virtual_environment_container.this must be replaced
~ node_name = "pve02" -> "pve03" # forces replacement
Plan: 1 to add, 0 to change, 1 to destroy.
```

Editing `target_node` and applying **destroys and rebuilds the guest**. The plan
gates refuse it, so what you actually see is red CI rather than a lost container —
but do not read that red as "the gate is being awkward". It is the gate working.

There is no declarative escape. `removed` cannot pair with `import` for an address
the config still declares (*"Removed resource still exists … but it is still
declared in configuration"*), and an `import` block cannot adopt over an existing
row. So placement is changed on the node and reconciled into state afterwards.

## The procedure

**1. Migrate.** `--restart` stops, moves, and starts. `--target-storage` is
mandatory going to pve03, which has **no LVM thin pool** — it was installed as
plain Debian on ext4, so `local-lvm` is inactive there and `local` (a directory
store) is its only container storage.

```bash
pct migrate <vmid> pve03 --restart --target-storage local
```

Only the `rootfs` line changes: `local-lvm:vm-<id>-disk-0` becomes
`local:<id>/vm-<id>-disk-0.raw`. Features, startup order, MAC, IP, tags and
timezone all survive — verified by diffing `pct config` before and after.

**2. Reconcile state.** Generic, driven by the live cluster, works on either repo:

```bash
./scripts/tf-state-repoint-node.sh                              # environments/homelab
./scripts/tf-state-repoint-node.sh ../media-iac/environments/media
```

It backs state up first and prints the `terraform state push` that undoes it.

**3. Point the config where the guests already are.** In `petedio-iac` that is
`var.target_node` plus the module's `datastore_id` default; check for guests that
set either **explicitly** — `runner_2` hardcoded `pve02` and was the one resource
still planning a replacement after everything else was clean.

**4. Read the plan.** Expect `0 to add, N to change, 0 to destroy`, where each
change is a lone `+ vm_id` plus `timeout_*` defaults. `terraform import` populates
`id` but not `vm_id`, so this is an in-place write of a value already true. One
apply converges it. **Any replacement in that plan means step 3 is incomplete.**

**5. Verify.** `./scripts/lab-verify.sh` asserts placement against intent, so a
half-finished move fails loudly rather than looking healthy from the wrong host.

## What it cost

38.5 GB of real data, but migration streams the **provisioned** size, not the
allocated one — a 4 G volume holding 2.49 G copied 4.0 GiB. Budget on provisioned.

Measured **116 MB/s**, near line rate. An `ssh dd` throughput test beforehand said
50 MiB/s and was wrong by more than 2×: it measured a proxy, not the mechanism.
Per-guest downtime ran 31 s (2 G) to 389 s (40 G).

## Traps

**A stray snapshot blocks migration.** Directory storage keeps raw files and cannot
hold snapshots, so `pct migrate` refuses. Guest 112 carried one named `asdf` from
2026-03-01. Find them before you start:

```bash
for id in $(pct list | awk 'NR>1{print $1}'); do pct listsnapshot $id | grep -v current; done
```

**Bind mounts must be `shared=1`** or Proxmox refuses to migrate (PET-325). Only
110 and 236 have them, and both stay on pve02, so this did not bite here.

**The bootstrap set moves itself.** Vault (223) holds every secret and re-seals on
stop; MinIO (221) holds the Terraform state for both repos; runner-233 runs the
applies. Migrate them **by hand from the Mac with CI quiet** — a runner migrating
itself kills its own job, and no Terraform can run while 221 is in flight. Do them
last. Vault came back sealed and the `dev.pdlab.vault-unseal` launchd agent had
already unsealed it before the state work started; do not assume that, check.

**Checks that hardcode a node report the service as broken.** Immediately after the
move `lab-verify` said `postgres not accepting`. Postgres was fine — the check ran
`pct exec 231` on pve02, where 231 no longer was. Every guest exec now goes through
`node_for` / `pct_on`. pve03 is reached as an unprivileged user, so `pct` needs
`sudo` there and not on pve02; that asymmetry is the other reason to funnel them.

## After

pve03 carries 16 guests at ~6 GB of 15 GB, load 0.84 on 8 cores. pve02 holds two
guests using 2.5 GiB, leaving its 4 cores to transcode.

The concentration is deliberate and worth restating: **pve03 now holds Vault,
Postgres, Authentik, Plane, both runners, ingress and CI.** Losing it loses the
platform. That was accepted because pve02 carries the fragile USB enclosures, and
moving the platform off the fragile node is the point — but it also ends the
CI split across nodes, since runner-232 was already on pve03.
