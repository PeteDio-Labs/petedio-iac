# Runbook — Deploy Co-latro to the poker-api LXC 230 (PET-12 / PET-43 / PET-44)

Operator steps to roll out the Co-latro app onto **LXC 230** (`poker-api-230`,
`192.168.50.230`): the backend image (Nexus → systemd Docker container on `:3020`) and
the static frontend (MinIO `co-latro-frontend` bucket → nginx on `:80`, proxying `/api`).

Terraform owns LXC 230's existence + hardware + network only (`environments/homelab/poker.tf`).
Everything host-level here is Ansible + two helper scripts. Linear: **PET-12** (parent) ·
**PET-43** (features) · **PET-44** (rollout) · **PET-54** (smoke test).

> [!CAUTION]
> This is committed to a **public** repo. Never paste a real secret, token, password, or
> `DATABASE_URL` here. Secrets come from Vault at run time via the helper scripts.

---

## How secrets are sourced (the policy boundary)

The rollout reads three secrets from Vault, but **not all under one policy** — the design
is least-privilege (see [`vault-seed.md`](./vault-seed.md) policy map):

| Secret | Vault path | Read by | Why |
|---|---|---|---|
| `DATABASE_URL` | `kv/poker/db` | **`poker-api` AppRole → Vault Agent on 230** (PET-57) | rendered on-host to a tmpfs env-file, never at rest / never through the deploy; policy `poker-api` reads only `kv/poker/db`. |
| Nexus creds | `kv/services/nexus` | `ansible`/`terraform` (both read `services/*` or via the wrapper) | registry pull auth |
| Frontend MinIO creds | `kv/services/minio-frontend` | `ansible` policy | a **bucket-scoped** svcacct (`kv/iac/minio` is tfstate-only and can't read this bucket) |

`scripts/deploy-poker-api.sh` logs in with the **`ansible`** AppRole and resolves only the
Nexus + MinIO `services/*` creds (passed as `no_log` extra-vars). **`DATABASE_URL` is no
longer resolved by the deploy** — since PET-57 the `vault-agent-co-latro` systemd unit on 230
auto-auths with the `poker-api` AppRole and renders it to `/run/co-latro/co-latro.env`
(tmpfs), restarting the backend on rotation.

---

## Prerequisites

- Vault unsealed; `ansible` AppRole creds present in the gitignored
  `iac/.secrets/ansible.{role_id,secret_id}` (see [`vault-seed.md`](./vault-seed.md)).
- **Vault Agent (PET-57): the `poker-api` AppRole `role_id`/`secret_id` seeded on 230** at
  `/etc/co-latro/vault-agent/{role_id,secret_id}` (root-only, `0600`). Mint with the root
  token after `vault-config` is applied (it creates the `poker-api` policy + AppRole):
  `vault read -field=role_id auth/approle/role/poker-api/role-id` and
  `vault write -f -field=secret_id auth/approle/role/poker-api/secret-id`. Without it the
  agent (and so the backend) won't start — the playbook warns and skips starting the agent.
- `kv/services/nexus` seeded (PET-42). `kv/services/minio-frontend` seeded — run
  `scripts/reseed-minio-frontend-vault.sh` once if missing (mints a `co-latro-frontend`-only
  MinIO svcacct).
- Backend image pushed to Nexus (`docker.pdlab.dev/co-latro-backend:<sha>` + `:latest`) and the
  frontend `dist/` uploaded to the MinIO `co-latro-frontend` bucket (both via the app repos' CI
  on merge, or manually).
- Controller has `ansible-galaxy collection install -r ansible/requirements.yml`
  (adds `community.docker`).
- SSH-as-root to 230 over `~/.ssh/id_ed25519_ansible` (the key TF installs).

---

## Step 1 — PET-43: set container features (out-of-band, once)

Docker in the unprivileged LXC needs `nesting=1,keyctl=1`, which a Proxmox API token can't set
(root@pam gotcha — see [`../GOTCHAS.md`](../GOTCHAS.md)). The script `pct set`s them on the node
and reboots 230 (empty until now → safe). Idempotent: no-op + no reboot if already set.

```bash
./scripts/lxc-features-230.sh
```

## Step 2 — migration safety gate (scratch DB)

The backend runs its migration on boot. It is **additive** (`CREATE TABLE` / `ADD CONSTRAINT` /
`CREATE INDEX` — no `DROP`/`TRUNCATE`/`DELETE`; verified in
`co-latro-backend src/db/migrations/0000_*.sql`). To be certain before touching the live `poker`
DB on `.231`, first-boot the image against a throwaway DB and inspect the output:

```bash
# On postgres-rds-231 (psql as admin), create a scratch DB owned by poker:
#   CREATE DATABASE poker_scratch OWNER poker;
# Run the image once against it (loopback example; adjust host/creds):
docker run --rm -e NODE_ENV=production -e PORT=3020 \
  -e DATABASE_URL='postgresql://poker:<PW>@192.168.50.231:5432/poker_scratch?sslmode=disable' \
  docker.pdlab.dev/co-latro-backend:latest
# Watch the logs: migrations apply, "/health UP", no destructive DDL. Then:
#   \c poker_scratch ; \dt   -> users, game_sessions present
#   DROP DATABASE poker_scratch;   (clean up)
```

Only proceed to Step 3 once the migration output is confirmed additive.

## Step 3 — PET-44: run the rollout

```bash
# Pin the image for a reproducible/rollback-able deploy (recommended):
IMAGE_TAG=<git-sha> ./scripts/deploy-poker-api.sh
# …or default to :latest:
./scripts/deploy-poker-api.sh
```

This installs Docker + nginx, logs in to Nexus, installs the **Vault Agent** that renders the
backend env-file (`DATABASE_URL`) to tmpfs, installs+starts the `co-latro-backend` systemd unit
(container on `127.0.0.1:3020`, gated on the agent-rendered env-file), drops the nginx site
(removing the distro default), and `mc mirror`s the frontend dist to `/var/www/co-latro`.
Re-runnable.

---

## Step 4 — PET-54: smoke test (closes PET-12)

On LXC 230 (`ssh root@192.168.50.230`) and from the LAN:

```bash
# Backend health — /health is at the ROOT, NOT under /api, so hit it directly:
ssh root@192.168.50.230 'curl -fsS http://127.0.0.1:3020/health'   # {"status":"UP"}
systemctl status co-latro-backend nginx                            # both active
docker logs co-latro-backend 2>&1 | tail -20                       # migrations applied, listening :3020

# Frontend reachable + SPA fallback (from the LAN):
curl -I  http://192.168.50.230/                  # 200, text/html
curl -sS http://192.168.50.230/some/deep/route | grep -q '<div id="app"' && echo "SPA fallback OK"

# Same-origin API through nginx (an actual /api route — /api/auth/login):
curl -sS -X POST http://192.168.50.230/api/auth/login \
  -H 'Content-Type: application/json' -d '{"name":"smoke"}'        # JSON (token or validation error), NOT index.html

# DB persistence: after a login → start-run, confirm a real row on .231:
#   psql … -c 'select count(*) from game_sessions;'   (>= the runs you created)

# Resilience:
systemctl restart co-latro-backend && sleep 5 && curl -fsS http://127.0.0.1:3020/health
```

Idempotency check: re-run `./scripts/deploy-poker-api.sh` → only expected `changed` (or none).

When green: mark **PET-54** done, comment results on **PET-12**, close PET-12.

---

## Notes / gotchas

- `mc mirror --remove` makes the web root a **mirror** of the bucket — files absent from the
  bucket are deleted locally (intended; the bucket is source of truth).
- The backend binds `127.0.0.1:3020` (nginx is the only consumer) — not LAN-exposed.
- `nginx -t` runs in the reload handler, so a bad config never reloads a broken nginx.
- Rollback: `IMAGE_TAG=<previous-sha> ./scripts/deploy-poker-api.sh` re-pulls + restarts.
- `DATABASE_URL` is delivered by a **Vault Agent** (PET-57): `vault-agent-co-latro.service`
  renders `/run/co-latro/co-latro.env` (tmpfs) from `kv/poker/db` and restarts the backend on
  rotation. Debug: `journalctl -u vault-agent-co-latro`; the secret is never on persistent disk.
