# Runbook — adopt the live Authentik SSO (LXC 119 / .119) under Terraform (import-before-apply)

This runbook covers the **manual, one-time operator steps** to bring the **already-live**
Authentik container — `authentik`, LXC **119** on **pve01**, `192.168.50.119`, serving
**SSO/LDAP behind `auth.pdlab.dev`** — under `petedio-iac` management **without recreating
it**, and to remove it from the **legacy** homelab-infra state so two states don't both own
it. Linear: **PET-123** (decision PET-103; gates the legacy-state retirement PET-50). The
container is declared in `environments/homelab/authentik.tf` as `module.authentik`.

> [!CAUTION]
> **Authentik is live SSO/LDAP — an outage breaks every downstream login.** `terraform
> import` does NOT touch the container (it only writes state), so the adoption itself is
> non-disruptive, but **any `apply` that shows a change to the LXC/NIC/DNS is a STOP**.
> Single-operator procedure on a backend with **no state locking** (MinIO — see
> `backend.tf`): do this **before** the PET-123 PR merges so CI's apply-on-merge can't fire
> mid-procedure. The autonomous loop never runs `import`/`apply`/`state` mutation.

---

## Why import first (do not skip this)

`module.authentik` is in config but the running container is **not** in the new Terraform
state. A bare `terraform apply` would plan to **create** LXC 119 from scratch — against a
VMID that already exists, that is destructive/failing. Importing writes the live container
into state **first**, so the subsequent plan is a diff against reality (ideally empty).

This container was **not** created by `modules/proxmox-lxc` (it predates it), so
`authentik.tf` + the PET-123 module knobs were authored to match its **live** config (read
read-only via `scripts/proxmox-ro-config.sh pve01 119`):

| Live (`pct config` equivalent)                         | How it's captured |
|--------------------------------------------------------|-------------------|
| `cores 2`, `memory 2048`, `swap 512`                   | module vars |
| `rootfs sdb3-storage:vm-119-disk-0,size=20G`           | `disk_size = 20`, `datastore_id = "sdb3-storage"` |
| `unprivileged 1`, `onboot 1`                           | module defaults |
| `ostype ubuntu`                                        | `os_type = "ubuntu"` |
| `net0 name=eth0 firewall=1 hwaddr=BC:24:11:C0:03:DA ip=…119/24` | `network_interface_firewall = true`, `mac_address`, `ipv4_address` (NIC name is the default eth0) |
| `nameserver 192.168.50.1`, **no** `searchdomain`       | `dns_servers = ["192.168.50.1"]`, `dns_domain = ""` (renders a nameserver but no searchdomain) |
| `features keyctl=1,nesting=1`                           | **out-of-band on the node** — `ignore_changes` (invisible/unmanageable via the API token) |
| `console 1` / `tty 2` / `cmode tty`                    | provider defaults + `console` is `ignore_changes` → no diff |

CT119 has **no** extra mount and **no** `lxc.idmap` (simpler than Nexus 106).

---

## Resource address & import ID

bpg's container import ID is `<node>/<vmid>`.

| Resource address (TF)                                       | Live object | Import ID  |
|-------------------------------------------------------------|-------------|------------|
| `module.authentik.proxmox_virtual_environment_container.this` | LXC 119 on pve01 | `pve01/119` |

---

## Steps (operator)

### 1. Import into the NEW (petedio-iac) state and prove a no-op

```sh
cd environments/homelab

# Pre-flight: confirm the live specs authentik.tf was written against haven't drifted (RO).
../../scripts/proxmox-ro-config.sh pve01 119

# Import the running container into the new state.
terraform import 'module.authentik.proxmox_virtual_environment_container.this' pve01/119

# ACCEPTANCE GATE: this plan must be a no-op for the LXC/NIC/DNS.
terraform plan
```

**Reading the plan:**
- ✅ Required: `0 to add, 0 to destroy`, and **no** change to the NIC (`firewall`, MAC),
  the disk, cpu/mem, or DNS (nameserver stays, no searchdomain added). Any
  add/destroy/recreate, or a `firewall: true -> false` / DNS change, is a
  **STOP-and-reassess** — do not apply through it.
- ℹ️ Expected **cosmetic, non-destructive** diff: `description` (live is empty;
  `authentik.tf` sets a clean TF-managed string — a UI-notes field only). You may also see
  state-side noise on the first plan (`+ vm_id`, `+ timeout_*` — provider attributes
  `import` doesn't populate, not API mutations). See `docs/GOTCHAS.md`.

### 2. Remove LXC 119 from the LEGACY (homelab-infra) state

So neither state thinks it owns the box twice. This is **`state rm` (drop tracking), NOT
`destroy`** — it never touches the running container.

```sh
# In the OLD homelab-infra repo / workspace (NOT petedio-iac):
terraform state list | grep -iE '119|authentik'   # find the exact old address
# e.g. proxmox_lxc.authentik  (Telmate) or module.<x>.<...>  — use what `state list` shows
terraform state rm '<the address from above>'
```

> [!WARNING]
> Run `state rm` only **after** the import in step 1 succeeded and its plan is a clean
> no-op — the new state must own the box before the old one lets go. **Never `terraform
> destroy`** in the old repo; that would delete live SSO. Do this before retiring the
> legacy state (PET-50), which this gates.

`terraform import` / `state rm` do not touch the container, so `auth.pdlab.dev` and LDAP
stay live throughout — no restart is involved in adopting it.

---

## The Ansible "match the running service" half is NOT done yet (blocked)

PET-123's Ansible scope (match the in-guest Authentik service idempotently) is **deferred**
— it needs in-container truth the autonomous loop cannot obtain (SSH-into-guest is forbidden;
PET-138 unblocked only the read-only **Proxmox** introspection / TF-import half), and the app
secrets live in **Vault .223** (never in repo). Author a `configure-authentik.yml` + role in
a follow-up once an operator captures, from **inside** CT119 (`pct enter 119`):

- [ ] How Authentik runs: the `docker compose` stack (server + worker + Postgres + Redis),
      the compose file location, and the image tag (`ghcr.io/goauthentik/server:<tag>`).
- [ ] Env / secret wiring: `AUTHENTIK_SECRET_KEY`, DB + Redis creds, the SMTP/LDAP outpost
      config — which **Vault `.223`** paths back them (reference by path, never inline).
- [ ] Volumes/mounts inside the guest (media, certs, custom templates) and their owners.
- [ ] The LDAP outpost: how `auth.pdlab.dev`'s LDAP is exposed and on what port.
- [ ] Package/repo provenance (Docker apt repo) so the role is idempotent.

Gate the first run with `--check` against the `authentik` inventory group (already added).
**Config-match only — no behavioural changes to a live SSO host.**
