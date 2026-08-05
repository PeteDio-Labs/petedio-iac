# minio role — the MinIO hosts (LXC 221 state backend + LXC 245 app data) — PET-124

Config-as-code for **both** MinIO hosts. One role, two consumers, and the difference
between them is the whole point:

| Host | Playbook | Buckets | In Terraform? |
|---|---|---|---|
| **minio-221** (`192.168.50.221`) | `configure-minio.yml` | `tfstate` | **No — never.** |
| **minio-data-245** (`192.168.50.245`) | `configure-minio-data.yml` | `obsidian-fs-mcs` (+ future app buckets) | **Yes** — `environments/homelab/minio-data.tf` |

**.221 is HAND-MANAGED by design** and has **no Terraform resource, ever** — Terraform
cannot create the host that stores Terraform's own state (bootstrap circularity). The
decision is the MinIO ADR (PET-102); the in-repo marker is
`environments/homelab/minio-state-backend.tf`; the disaster path is
`docs/runbooks/minio-221-rebuild.md`.

**.245 has no such circularity** — nothing in its own lifecycle depends on it — so it is
ordinary IaC. That is why app buckets belong there and **not** on .221: parking them on
the state backend would hand them a host TF can never plan or rebuild, on the same disk
as `tfstate`.

> **New app bucket?** Add it to `minio_buckets` in
> `inventory/group_vars/minio_data.yml`. Do not add it to .221, and do not add it to this
> role's defaults.

What the role does (idempotent; a second run reports **no changes** and triggers **no
restart**):

- Pinned, checksum-verified **MinIO server** + **mc client** binaries → `/usr/local/bin`
  (versions/sha256 in `defaults/main.yml`, verified against the official `.sha256sum`
  sidecars — bump version + hash together, cf. PET-111)
- `minio-user` system account + the data directory (`/var/lib/minio`)
- `/etc/default/minio` environment file (`0640`, root creds injected at runtime — see
  below) and the `minio.service` systemd unit
- Converges every bucket in **`minio_buckets`** (`tasks/buckets.yml`): creates it if
  absent, **enables versioning** if off (the recovery net for the lock-light backend —
  `docs/GOTCHAS.md` → "MinIO S3 state backend"), and sets a **hard quota** if the entry
  declares `quota_bytes`. It never deletes a bucket, never suspends versioning, and never
  touches object data. The default list is exactly `tfstate`, so .221 is unaffected.
- UFW: allow `9000`/`9001` from `192.168.50.0/24`
- *Optional, off by default:* an off-host **backup** of `minio_backup_bucket` (`mc mirror`
  + systemd timer) — enable with `minio_backup_enabled` once you've chosen a destination

### Declaring buckets

```yaml
minio_buckets:
  - name: obsidian-fs-mcs
    quota_bytes: 5368709120   # 5 GiB. BYTES, not "5gi" — see below.
```

`quota_bytes` is deliberately an integer rather than mc's human `5gi` form: the converge
compares it against the `quota` field of `mc quota info --json`, so a unit-free value
keeps the check idempotent instead of re-setting the quota (and reporting *changed*) on
every run. Omit the key entirely for no quota.

`tasks/buckets.yml` is split out so it can be exercised on its own against a throwaway
MinIO — it needs only an authenticated `mc` alias, no systemd and no host. Worth using:
this file converges the bucket holding Terraform's state, so "a re-run reports zero
changes" is a regression test, not a nicety.

## Run the role

```sh
cd ansible/
# resolve root creds from Vault into a 0600 @file, then run (see playbook header):
umask 077
vault kv get -format=json kv/iac/minio-root | \
  jq '{minio_root_user: .data.data.root_user, minio_root_password: .data.data.root_password}' \
  > /tmp/minio-secrets.json
ansible-playbook playbooks/configure-minio.yml -e @/tmp/minio-secrets.json
shred -u /tmp/minio-secrets.json
```

Re-run to confirm idempotence (second run = no changes). Use `--check` for the
binary/unit/UFW diff; the mc-driven bucket/versioning tasks are command modules and are
skipped under `--check`, so do a real run (in a no-apply window) to converge versioning.

## Secrets — Vault path reference only, NOTHING baked in

**No credential lives in this repo or this role.** Two distinct credentials, two Vault
paths:

| Credential | Vault path | Owner | Used for |
|---|---|---|---|
| **.221** root (admin) | `kv/iac/minio-root` (`root_user`, `root_password`) | this role (consumed as a `no_log` extra-var) | server config + mc admin |
| **tfstate-scoped** svcacct | `kv/iac/minio` (`access_key`, `secret_key`) | **`scripts/reseed-minio-vault.sh`** | the S3 backend (`AWS_*`) |
| **.245** root (admin) | `kv/iac/minio-data-root` (`root_user`, `root_password`) | **`scripts/seed-minio-data-root.sh`** | server config + mc admin on .245 |
| **obsidian-scoped** svcacct | `kv/services/minio-obsidian` | **`scripts/reseed-minio-obsidian-vault.sh`** | Obsidian sync clients |

The two hosts have **separate root credentials on purpose** — one compromised app
credential must not reach the state backend.

The role deliberately does **not** mint the tfstate svcacct — `reseed-minio-vault.sh`
already owns minting it (least-privilege, scoped to the `tfstate` bucket) and writing it
to `kv/iac/minio` with `vault kv put`. Keeping that in one place avoids the `kv put`
clobber that would wipe root fields if both shared one path. On a rebuild you run the
role first (root creds), then `reseed-minio-vault.sh` to re-mint the backend svcacct.

> `kv/iac/minio-root` is a **new** path this role references — seed it once (the rebuild
> runbook has the step). The existing `ansible` Vault policy already reads `kv/iac/*`, so
> no policy change is needed.

## Why this host is not in Terraform

`backend.tf` points Terraform's state at `http://192.168.50.221:9000` (bucket `tfstate`).
A `proxmox_virtual_environment_container` for .221 would have to be created by a
`terraform apply` whose own state lives on .221 — you can't bootstrap the state store
from the thing that needs it. So .221 is created by hand (the runbook) and kept as code
here via Ansible only. See `environments/homelab/minio-state-backend.tf` and the ADR.
