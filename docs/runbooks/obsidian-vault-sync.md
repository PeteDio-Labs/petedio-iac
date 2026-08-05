# Runbook — Obsidian vault sync (FS MCS) over MinIO 245 + Tailscale

Sync the **FS MCS** Obsidian vault (Full Sail MSCS coursework, `~/FS MCS` on the Mac)
across Mac / iPhone / iPad / Windows PC, through the `obsidian-fs-mcs` bucket on
**minio-data-245**, reached over the tailnet. **No public URL, no Cloudflare route.**

| | |
|---|---|
| Endpoint | `http://192.168.50.245:9000` (S3 API) · `:9001` (console) |
| Bucket | `obsidian-fs-mcs` — versioned, 5 GiB hard quota |
| Credential | Vault `kv/services/minio-obsidian` (`access_key`, `secret_key`, `endpoint`, `bucket`) |
| Reachability | tailnet `tailef7394.ts.net` via the `tailscale-244` subnet router (`192.168.50.0/24`) |
| Plugin | Obsidian community plugin **Remotely Save** (S3-compatible) |
| Infra | `environments/homelab/minio-data.tf` · `ansible/playbooks/configure-minio-data.yml` |

## Why there is no public URL, and why that is not a limitation

Cloudflare Access authenticates either a **browser** (redirect + session cookie) or a
caller that can set `CF-Access-Client-Id` / `CF-Access-Client-Secret` headers. The Obsidian
sync plugin is a plain S3 client and does neither, so a Cloudflare route to `:9000` would
have to be **ungated and public** — a MinIO S3 API open to the internet, protected by
nothing but the access key. That is strictly worse than the alternative.

`tailscale-244` already advertises `192.168.50.0/24` into the tailnet, so every device
reaches `192.168.50.245` inside WireGuard with zero public ingress. **Plain HTTP is
correct here** — the whole path is already encrypted, and the endpoint is unroutable from
the internet. Do not "fix" this by adding a `cloudflare-routes.tf` entry.

This also means: **if Tailscale is off, sync fails.** That is the design working, not a
bug. The Mac is on `192.168.86.x`, a different LAN from the homelab — Tailscale is the
only path, not an optimization.

---

## First build (once)

Order matters — step 2 must precede MinIO existing, step 4 requires it running.

```bash
# 1. LXC 245 — via PR + apply-on-merge (never `terraform apply` by hand)
#    Confirm the plan is 1-to-add / 0-to-destroy before merging.

# 2. Root credentials -> Vault kv/iac/minio-data-root
./scripts/seed-minio-data-root.sh

# 3. MinIO + the bucket + versioning + quota
./scripts/deploy-minio-data.sh
./scripts/deploy-minio-data.sh          # re-run: must report changed=0

# 4. The bucket-scoped credential the devices will use
./scripts/reseed-minio-obsidian-vault.sh
```

Health check (needs the tailnet up):

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.50.245:9000/minio/health/ready
```

Read the device credential:

```bash
vault kv get kv/services/minio-obsidian
```

---

## Per-device setup

### Tailscale first, on every device

The tailnet is `tailef7394.ts.net`. Each client must **accept subnet routes** — this is
off by default and is the single most common reason "it worked on the Mac but not the
phone".

| Device | Tailscale |
|---|---|
| **Mac** (`m1-mac`) | Already a node. Start it (it is currently stopped) and enable **Use Tailscale subnet routes** in Preferences. |
| **iPhone** (`iphone171`) | Already a node. Settings → enable **Use subnet routes**. |
| **iPad** | Not yet a node. Install Tailscale, sign in, enable **Use subnet routes**. |
| **Windows PC** | Not yet a node. Install Tailscale, sign in, then `tailscale up --accept-routes`. |

Join new devices by **signing in interactively**. Do not reach for
`kv/services/tailscale` — that is a *single-use, 90-day node auth key* for the subnet
router LXC, almost certainly already spent, and not meant for user devices.

Verify from the device before touching Obsidian:

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.50.245:9000/minio/health/ready
```

> **Mac CLI note:** `/usr/local/bin/tailscale` is a dangling symlink to a pre-App-Store
> path. The working binary is
> `/Applications/Tailscale.localized/Tailscale.app/Contents/MacOS/Tailscale`.

### Then Obsidian + Remotely Save

1. Obsidian → Settings → **Community plugins** → turn off Restricted Mode → Browse →
   install and enable **Remotely Save**.
2. In Remotely Save settings, choose service **S3** and set:

| Setting | Value |
|---|---|
| Endpoint / address | `http://192.168.50.245:9000` — full scheme **and** port |
| Region | `us-east-1` |
| Access key / Secret key | from `vault kv get kv/services/minio-obsidian` |
| Bucket | `obsidian-fs-mcs` |
| **S3 URL style** | **Path Style** — required for MinIO; virtual-host style will not resolve |
| **Bypass CORS** | **on** |

3. Exclude per-device and OS cruft from sync (Remotely Save's ignore/exclude paths):

```
.DS_Store
.obsidian/workspace.json
.obsidian/workspace-mobile.json
```

Vault *config* is worth syncing; vault *layout* is per-device and will thrash if shared.
This mirrors the split `petedio-vault`'s own `.gitignore` already uses.

4. Enable auto-sync on start/quit and on an interval.
5. **Order matters on first run:** sync **from the Mac first** — that is the upload of
   record. Only then pull down on the other devices, into an empty vault named `FS MCS`.

CORS configuration on MinIO is *not* needed for current Obsidian (desktop ≥ 0.13.25,
mobile ≥ 1.1.1).

---

## Living with it — the two real limits

- **Sync only runs while Obsidian is open.** Background sync is not possible on mobile;
  an edit made and then backgrounded without a sync does not propagate until next open.
  Habit: let the sync finish before switching devices.
- **Conflicts duplicate, they do not merge.** Smart three-way merge is a paid Remotely
  Save feature; the free tier keeps both copies. With one user this is rare, and the
  duplicate is visible rather than silent.

**Recovery is bucket versioning** — deliberately, there is no git backup of this vault.
Every device also holds a complete local copy, so total loss requires losing all of them.
To recover a note deleted by a bad sync, list and restore the prior version:

```bash
mc --config-dir "$(mktemp -d)" alias set ob http://192.168.50.245:9000 <access_key> <secret_key>
mc ls --versions ob/obsidian-fs-mcs/<path>
mc cp --version-id <id> ob/obsidian-fs-mcs/<path> ./restored.md
```

Never suspend versioning on this bucket, and do not remove the quota — it is what bounds a
runaway sync loop inside the host's 16 GiB disk.

---

## Rotating the credential / revoking a lost device

There is no per-device credential, so a lost or retired device is handled by rotating the
one shared key:

```bash
./scripts/reseed-minio-obsidian-vault.sh --rotate
```

This mints a new bucket-scoped service account, writes it to
`kv/services/minio-obsidian`, and **prints the older service accounts, which remain valid
until removed**. So:

1. Rotate.
2. Update Remotely Save on every device you still own.
3. Only then delete the old account — this is what actually revokes the lost device:

```bash
mc admin user svcacct rm adm <old-access-key>
```

Doing step 3 first locks out every device at once, including the ones you still have.

Rotating the **root** credential is a separate, rarer operation
(`./scripts/seed-minio-data-root.sh --rotate`, then re-run `deploy-minio-data.sh` to
restart MinIO with it). Existing service accounts keep their own keys and survive it.

---

## Adding another vault or app bucket

Add an entry to `minio_buckets` in `ansible/inventory/group_vars/minio_data.yml` and
re-run `./scripts/deploy-minio-data.sh`, then mint a scoped credential for it (copy
`scripts/reseed-minio-obsidian-vault.sh`).

**Do not** put app buckets on **minio-221** — that host holds Terraform's state, is
hand-managed by design, and can never be planned or rebuilt by Terraform. See
`environments/homelab/minio-state-backend.tf` and `ansible/roles/minio/README.md`.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Timeout / no route from any device | Tailscale down, or **subnet routes not accepted** on that client |
| Works on Mac, fails on phone | Subnet routes not enabled in the iOS Tailscale app |
| `Access Denied` on the bucket | Using a credential scoped to a different bucket, or the key was rotated and this device wasn't updated |
| Sees no buckets at all | Expected — the scoped key can only see `obsidian-fs-mcs`. Not a fault. |
| Endpoint refuses connection but ping works | MinIO not running, or UFW: the role allows `9000`/`9001` from `192.168.50.0/24` only. Tailnet clients pass because the subnet router SNATs them to `192.168.50.244`. |
| Writes start failing, reads fine | Bucket quota reached (5 GiB) — `mc quota info` to confirm |
