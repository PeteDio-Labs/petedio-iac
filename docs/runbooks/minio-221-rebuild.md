# Runbook — rebuild the MinIO Terraform state backend (LXC 221 / .221)

This runbook is the **disaster-recovery path** for **minio-221** (`192.168.50.221:9000`,
bucket `tfstate`), the host that backs **all** Terraform state (`environments/homelab/backend.tf`).
It covers a from-scratch rebuild: **bare LXC create → Ansible → restore the state bucket
from backup → `terraform init`**. Linear: **PET-124**.

.221 is **HAND-MANAGED by design** — there is **no Terraform resource** for it (you can't
bootstrap the state store from the resource that depends on it; see the MinIO ADR /
PET-102 and `environments/homelab/minio-state-backend.tf`). So this host is rebuilt by
hand using this document, **not** by `terraform apply`.

> [!CAUTION]
> **This host holds the only authoritative copy of Terraform state.** The backend has no
> external lock manager (S3-native `use_lockfile` only) and **bucket versioning is the
> recovery net**. While .221 is down or being rebuilt, **no `terraform plan`/`apply` can
> run** anywhere (CI included) — they all point at this bucket. **Pause CI** (and tell any
> other operator) before you start, and don't un-pause until Step 6 verifies a clean
> `terraform init` + `state list`.

---

## When to use this

- .221 is lost / corrupted / being migrated to a new node, **or**
- you're standing up a replacement state-backend host from nothing.

For a *routine* config change (binary bump, versioning, UFW) you do **not** need a
rebuild — just re-run the role (`ansible-playbook playbooks/configure-minio.yml …`,
idempotent). This runbook is the **total-loss** path.

---

## Preconditions

- **A current off-host backup of the `tfstate` bucket exists** (see *Off-host backup* at
  the bottom). Without it, a rebuild starts from an **empty** bucket and **all Terraform
  state is lost** — every resource would look like it needs re-creating. This backup is
  the difference between a 20-minute rebuild and a homelab-wide incident.
- **Vault (.223) is up and reachable** — the root creds and the tfstate svcacct are
  re-seeded from it. (Vault does not depend on MinIO, so it survives a .221 loss.)
- **Proxmox access** to the node that hosts .221. Per the Homelab Inventory doc this is
  **pve01**; confirm there before creating the container.
- **The ansible-automation SSH key** (`~/.ssh/id_ed25519_ansible`, = `LXC_SSH_PUBLIC_KEY`)
  — the role connects as `root` over it (inventory `minio` group).
- The controller has `ansible`, `vault`, `terraform`, `mc`, and `jq` on `PATH`.

> [!NOTE]
> Confirm the VMID/IP/template/disk against the Linear **Homelab Inventory & IP/VMID
> Scheme** doc — it is authoritative. The values below (VMID **221**, IP **192.168.50.221**,
> last-octet = VMID convention) match the scheme at time of writing; do not re-derive them
> here if the doc has moved on.

---

## Procedure

### Step 1 — create the bare LXC by hand (Proxmox)

On the hosting node (**pve01**), create an unprivileged Debian LXC. This is the **one**
container created by hand rather than by `modules/proxmox-lxc` — keep it minimal and
matching the scheme:

- **VMID** `221`, **hostname** `minio-221`
- **Static IP** `192.168.50.221/24`, gateway `192.168.50.1`
- **Bridge `vmbr1`** — on **pve01 the LAN/uplink bridge is `vmbr1`, NOT `vmbr0`**
  (`vmbr0` = `eno1`, a gateway-less segment → 100% outbound loss). This is the single
  most common way to brick a fresh pve01 container; see `docs/GOTCHAS.md`.
- Debian 12 template, `2` cores / `2 GB` RAM is ample (MinIO single-node + a tiny state
  bucket). Disk: the OS disk is fine for `tfstate` (state is megabytes); give headroom
  (e.g. 16–32 GB) and confirm the storage target against the Inventory doc.
- Inject the **ansible-automation public key** as root's authorized key (or your bootstrap
  key, then let the role/your tooling install the automation key).
- Start the container and confirm `ssh root@192.168.50.221` works and it can reach the
  internet (`curl -fsSI https://dl.min.io >/dev/null`) and Vault (`192.168.50.223:8200`).

> [!NOTE]
> MinIO is a plain userspace server — it does **not** need the `nesting`/`keyctl`
> container features that the Docker/containerd LXCs need (the `root@pam` co-ownership
> gotcha in `docs/GOTCHAS.md` does **not** apply here). A stock unprivileged LXC is enough.

### Step 2 — seed the MinIO root credential in Vault (first build only)

The role reads MinIO root creds from **`kv/iac/minio-root`**. On a brand-new build (or if
the path was never seeded), create it with a freshly generated strong credential:

```bash
export VAULT_ADDR="https://192.168.50.223:8200"
export VAULT_CACERT="$(git rev-parse --show-toplevel)/environments/homelab/vault-ca.crt"
# VAULT_TOKEN / AppRole as usual — never echo it.

vault kv put kv/iac/minio-root \
  root_user="minioadmin-$(openssl rand -hex 3)" \
  root_password="$(openssl rand -base64 24)"
```

(The existing `ansible` Vault policy already reads `kv/iac/*`, so no policy change is
needed.) If you're rebuilding and intend to **reuse** the prior root credential, skip this
step — the role will read whatever `kv/iac/minio-root` holds.

### Step 3 — run the Ansible role

From `ansible/`, resolve the root creds into a `0600` `@file` and run the play (the
`minio` inventory group already targets `192.168.50.221`):

```bash
umask 077
vault kv get -format=json kv/iac/minio-root | \
  jq '{minio_root_user: .data.data.root_user, minio_root_password: .data.data.root_password}' \
  > /tmp/minio-secrets.json

ansible-playbook playbooks/configure-minio.yml -e @/tmp/minio-secrets.json

shred -u /tmp/minio-secrets.json
```

This installs the pinned MinIO + mc binaries, the systemd service, opens UFW
`9000`/`9001` from the LAN, **creates the empty `tfstate` bucket, and enables versioning**.
Confirm the service is healthy:

```bash
ssh root@192.168.50.221 'systemctl is-active minio && \
  curl -fsS http://127.0.0.1:9000/minio/health/ready && echo READY'
```

> [!IMPORTANT]
> At the end of Step 3 the bucket exists but is **EMPTY**. Do **not** run `terraform init`
> yet — an empty bucket is indistinguishable from "everything destroyed". Restore first
> (Step 4).

### Step 4 — restore the `tfstate` bucket from the off-host backup

Point `mc` at the new server and at wherever the backup lives, then mirror the backup
**into** the fresh bucket. Substitute your real backup target (see *Off-host backup*):

```bash
# on the controller (or on .221) — uses the root creds you just seeded
mc alias set local      http://192.168.50.221:9000 "$ROOT_USER" "$ROOT_PASSWORD"
mc alias set offsite    <your-backup-endpoint>      <ak> <sk>     # or a mounted path

# restore objects (and versions) from the backup into the live bucket
mc mirror --overwrite --preserve offsite/tfstate-backup local/tfstate

# sanity: the state object is present
mc ls local/tfstate/homelab/
#   expect: terraform.tfstate
```

> [!WARNING]
> Restore **into** the bucket (`offsite/… → local/tfstate`). Double-check direction — a
> reversed `mc mirror` would overwrite your **backup** with the empty bucket. Versioning
> is on, so a mistake is recoverable, but get it right the first time.

### Step 5 — re-mint the tfstate-scoped backend service account

The backend authenticates with a **tfstate-scoped svcacct** stored at `kv/iac/minio`
(separate from root). A rebuilt MinIO has no svcacct yet — re-mint it with the existing
script, which also writes it to Vault and proves `terraform init`:

```bash
cd "$(git rev-parse --show-toplevel)"
MINIO_ROOT_USER="$ROOT_USER" MINIO_ROOT_PASSWORD="$ROOT_PASSWORD" \
  ./scripts/reseed-minio-vault.sh
```

This mints a least-privilege svcacct (scoped to the `tfstate` bucket), writes
`kv/iac/minio` (`access_key`/`secret_key`), verifies it, and runs `terraform init`.

### Step 6 — `terraform init` + verify state, then un-pause CI

```bash
cd environments/homelab
export AWS_ACCESS_KEY_ID="$(vault kv get -field=access_key kv/iac/minio)"
export AWS_SECRET_ACCESS_KEY="$(vault kv get -field=secret_key kv/iac/minio)"

terraform init -reconfigure
terraform state list | head        # expect the real resources, NOT empty
terraform plan                     # expect: "No changes" (or only intended drift)
```

> [!CAUTION]
> **Read the plan.** A green init with an **empty** `state list`, or a plan that wants to
> **create everything**, means the restore (Step 4) didn't land — the bucket is empty or
> wrong. **STOP, do not apply**, re-do Step 4 from a known-good backup. Only when
> `state list` shows the real resources and `plan` is clean do you **un-pause CI**.

---

## Off-host backup of the state bucket (set up + cadence)

The rebuild above is only as good as the backup it restores from. Set this up **now**, on
the live host, not at disaster time.

### Pick a destination (off .221)

The destination must **not** live on .221 (a host loss must not take the backup with it).
Options, in rough order of preference for this homelab:

- **Another MinIO/S3 alias** — e.g. the old MinIO (`.115`) or pve02 object storage:
  `mc alias set offsite http://<host>:9000 <ak> <sk>` then mirror to
  `offsite/tfstate-backup`.
- **A mounted off-host share** (e.g. pve02 NFS — see PET-127): mirror to a path alias.

Whatever you choose, the bucket/target should itself have **versioning or snapshots** so a
bad mirror can't silently poison the only backup.

### Enable the role-managed backup timer

The role ships an opt-in `mc mirror` backup behind a systemd timer. Once the destination
alias exists on .221 (configure it under root's `~/.mc`), enable it:

```yaml
# group_vars or -e extra-vars for configure-minio.yml
minio_backup_enabled: true
minio_backup_dest: "offsite/tfstate-backup"   # your alias/path
minio_backup_oncalendar: "daily"              # systemd OnCalendar=
```

Re-run `configure-minio.yml`; the role installs `minio-tfstate-backup.{service,timer}` and
enables the timer. First run + verify:

```bash
ssh root@192.168.50.221 'systemctl start minio-tfstate-backup.service && \
  systemctl status minio-tfstate-backup.service --no-pager'
mc ls offsite/tfstate-backup/homelab/          # expect terraform.tfstate present
```

### Check cadence (write it on the calendar)

- **Backup runs:** daily (timer `OnCalendar=daily`, `Persistent=true` so a powered-off
  host catches up on boot).
- **Operator verification:** **monthly** — confirm the timer is `active` (`systemctl
  list-timers minio-tfstate-backup.timer`), the destination has a `terraform.tfstate`
  object **newer than ~24h**, and (quarterly) do a **restore drill**: `mc mirror` the
  backup into a throwaway bucket and `terraform init` against it to prove it's restorable.
  An untested backup is a guess, not a recovery plan.

---

## Verification (done = all of these pass)

```bash
# 1) Service healthy + versioning ON
ssh root@192.168.50.221 'systemctl is-active minio'                  # active
mc version info local/tfstate                                        # Enabled

# 2) State is real, not empty
cd environments/homelab && terraform state list | wc -l             # > 0
terraform plan                                                      # No changes (or intended)

# 3) Backup is fresh and restorable
mc ls offsite/tfstate-backup/homelab/                               # recent terraform.tfstate
systemctl list-timers minio-tfstate-backup.timer                    # next run scheduled
```

---

## Rollback / recovery

- **Restored from a stale/empty backup → plan wants to recreate everything:** do **NOT**
  apply. The live infra is unchanged; only state is wrong. Re-restore from a better backup
  version (the backup target's versioning), or reconstruct via `terraform import` for the
  affected resources. Apply only once `plan` is clean.
- **Corrupted a state object on the live bucket:** the `tfstate` bucket has **versioning
  on** — restore the previous object version (`mc` / console) and re-`init`.
- **Reversed the restore mirror (overwrote the backup):** the backup target should itself
  be versioned/snapshotted — roll it back there before retrying.
- **MinIO won't start after the role run:** check `journalctl -u minio` on .221; the usual
  causes are a bad `/etc/default/minio` (env file) or the data dir not owned by
  `minio-user`. Re-running the role converges both.
