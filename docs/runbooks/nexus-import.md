# Runbook — adopt the live Nexus registry (LXC 106 / .111) under Terraform (import-before-apply)

This runbook covers the **manual, one-time operator steps** to bring the **already-live**
Nexus registry container — `nexus-registry`, LXC **106** on **pve01**, `192.168.50.111`,
behind `registry.pdlab.dev` + `docker.pdlab.dev` — under `petedio-iac` management
**without recreating it**. Linear: **PET-122** (decision: PET-101). The container is
declared in `environments/homelab/nexus.tf` as `module.nexus`.

> [!CAUTION]
> **`terraform import` rewrites the SHARED MinIO state.** Single-operator procedure on a
> backend with **no state locking** (MinIO doesn't speak DynamoDB — see `backend.tf`).
> Ensure **no concurrent apply** can run while you work: do this **before** the PET-122 PR
> merges, so CI's apply-on-merge cannot fire mid-procedure. The autonomous loop never runs
> `import`/`apply` — these steps are operator-only (`root@pam`-equivalent on his Mac/CI).

---

## Why import first (do not skip this)

`module.nexus` is in config but the running container is **not** in Terraform state. A bare
`terraform apply` would plan to **create** LXC 106 from scratch — against a VMID that already
exists, that is destructive/failing, and it would clobber the **load-bearing NFS-backed blob
store** bind mount. Importing writes the live container into state **first**, so the
subsequent plan is a diff against reality (ideally empty) instead of a create-from-nothing.

This container was **not** created by `modules/proxmox-lxc` — it's a community-scripts
"Docker LXC". `nexus.tf` + the PET-122 module knobs were authored to match its **live** config
(read read-only via `scripts/proxmox-ro-config.sh pve01 106`), specifically:

| Live (`pct config` equivalent)                         | How it's captured |
|--------------------------------------------------------|-------------------|
| `cores 4`, `memory 2048`, `swap 512`                   | module vars |
| `rootfs sdb3-storage:vm-106-disk-0,size=40G`           | `disk_size = 40`, `datastore_id = "sdb3-storage"` |
| `unprivileged 1`, `onboot 1`, `ostype debian`          | module defaults |
| `net0 name=eth1 … hwaddr=BC:24:11:F0:6A:D5 ip=…111/24` | `network_interface_name = "eth1"`, `mac_address = "BC:24:11:F0:6A:D5"`, `ipv4_address` |
| **no** `nameserver`/`searchdomain`                     | `dns_servers = []` (renders no dns block) |
| `mp0 /mnt/pete/nexus-data,mp=/nexus-data`              | **ignored** (`mount_point` in `ignore_changes`) — out-of-band, like features |
| `features nesting=1,keyctl=1`; raw `lxc.idmap`/apparmor | **out-of-band on the node** — invisible to the provider (set by community-scripts) |

---

## Resource address & import ID

bpg's container import ID is `<node>/<vmid>`.

| Resource address (TF)                               | Live object | Import ID  |
|-----------------------------------------------------|-------------|------------|
| `module.nexus.proxmox_virtual_environment_container.this` | LXC 106 on pve01 | `pve01/106` |

---

## Steps (operator)

```sh
cd environments/homelab

# 0. Pre-flight: confirm the live specs nexus.tf was written against haven't drifted.
#    (read-only; from the loop host or anywhere with the PVEAuditor token)
../../scripts/proxmox-ro-config.sh pve01 106

# 1. Import the running container into state.
terraform import 'module.nexus.proxmox_virtual_environment_container.this' pve01/106

# 2. The acceptance gate: this plan MUST be a no-op for the LXC/NIC/mount.
terraform plan
```

### Reading the plan — what "no-op" means here

- **Required:** `0 to add, 0 to destroy`, and **no** change to the NIC (`eth1`/MAC), the
  disk, memory/cpu, or the `mp0` mount. Any add/destroy/recreate of the container, NIC, or
  mount is a **STOP-and-reassess** — do not apply through it; re-check the live config and
  the module knobs.
- **Expected cosmetic, non-destructive diffs** (safe to apply; both are UI-notes fields, not
  runtime behaviour):
  - `description` — community-scripts ships a big HTML blob; `nexus.tf` sets a clean
    TF-managed string. The plan will show this one-field update.
  - `tags` — the live container has a whitespace-only `tags` value that bpg may normalise.
- If you want a **strictly empty** plan instead of accepting the cosmetic `description`
  update, add `description` (and/or `tags`) to the module's `ignore_changes` — but the
  cleaner outcome is to apply the one-field description update so the Proxmox UI reflects
  IaC ownership.

`terraform import` does not touch the container, so `registry.pdlab.dev` / `docker.pdlab.dev`
stay live throughout; no restart is involved in adopting it into state.

---

## The Ansible "match the running service" half is NOT done yet (blocked)

PET-122's Ansible scope (match the in-guest Nexus service idempotently) is **deferred** — it
needs in-container truth that the autonomous loop cannot obtain (SSH-into-the-guest is
forbidden by the loop's hard rules, and PET-138 unblocked only the read-only **Proxmox**
introspection / TF-import half). The TF capture above is complete and independently useful;
the service-config role should be authored in a follow-up once an operator captures, from
**inside** CT106 (`pct enter 106`):

- [ ] How Nexus runs: a `docker run`/`docker compose` unit, or native? The compose/service
      file(s) and the Nexus image + tag (`sonatype/nexus3:<tag>`?).
- [ ] The data path inside the guest: confirm Nexus's `nexus-data` lives on the `mp0` mount
      (`/nexus-data`) and the `nexus` UID/GID matches the `lxc.idmap` (host 200 ↔ guest 200).
- [ ] Docker daemon config (registry/proxy settings, `daemon.json`), and how the two edge
      hostnames are served (reverse proxy in-guest vs. cloudflared route only).
- [ ] Any cron/systemd timers (blob-store compaction, backups).
- [ ] Package/repo provenance so the role can be idempotent (apt sources, Docker repo).

Drop that capture into a `configure-nexus.yml` + role mirroring `configure-runner-docker.yml`,
and gate the first run with `--check` against the `nexus` inventory group (already added).
