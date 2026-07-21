# mongodb role — resume-builder app database (resume-242)

Native MongoDB 8.0 (official `mongodb-org` apt repo, pinned to the 8.0 line — supported to
2029-10) for the Resume Builder app. Localhost-only: the SvelteKit app runs on the same
host, so unlike the postgres RDS host there's no LAN bind, no CIDR allowlist.

## What it installs

- MongoDB 8.0 (`mongodb-org`), `bindIp 127.0.0.1`, `wiredTiger.engineConfig.cacheSizeGB`
  `0.25` (small footprint — 242 is a shared 6G-RAM LXC), `security.authorization: enabled`
  from the start.
- The app's SCRAM user (`mongodb_app_user`, default `resume-app`), scoped `readWrite` on
  the `mongodb_app_db` database (default `resume`) only — never an admin credential.
  Bootstrapped idempotently via Mongo's **localhost exception**: a localhost connection
  may run one `createUser` while the users collection is empty, even with authorization
  already enabled, so there's no disable-auth-then-enable-then-restart dance. Re-runs
  check `db.auth(...)` first and no-op if the user already works.
- A nightly `mongodump --archive --gzip | mc pipe` backup straight to a versioned MinIO
  bucket (`resume-mongo-backups`, default) — no local staging file, no remote pruning
  (bucket versioning is the retention net, same convention as `vault-snapshot`).

## Secrets — required extra-vars, no committed defaults

- `mongodb_app_password` — resolve from Vault `kv/services/resume-builder`
  (field `mongo_app_password`).
- `mongodb_backup_minio_access_key` / `_secret_key` — a **scoped** svcacct for the
  `resume-mongo-backups` bucket (fields `mc_access_key` / `mc_secret_key`), same Vault
  path. Only required if `mongodb_backup_enabled` (default `true`).

Pass both via a 0600 JSON `@file`, same pattern as `configure-postgres.yml` /
`scripts/deploy-poker-api.sh` — see `configure-mongodb.yml`'s header for the exact
command. Neither has a default; a bare re-run without them fails the `assert` at the top
of `tasks/main.yml` rather than silently reusing a stale/placeholder value.

## Known gap

Unlike `vault-snapshot` (which self-serves its MinIO creds from a live Vault Agent on the
same host), resume-242's Vault Agent AppRole was retired with the agent fleet in P0 and a
replacement hasn't been provisioned yet. So the backup script's MinIO creds are baked into
a root-only env file (`/etc/resume-mongo-backup.env`) at playbook-run time instead of
fetched at runtime. Revisit if/when a fresh Vault Agent identity lands for this host.

## Prerequisites (one-time, operator)

1. Create the `resume-mongo-backups` MinIO bucket + a scoped svcacct, seed
   `kv/services/resume-builder` with `mongo_app_password` / `mc_access_key` / `mc_secret_key`.
2. `mc mb <alias>/resume-mongo-backups && mc version enable <alias>/resume-mongo-backups`
   — the backup script's precondition check fails loudly (not silently) if this is skipped.
3. Run `configure-mongodb.yml` with the extra-vars above.
4. **Restore test once** (Phase 1 acceptance criterion, planning doc §5): `mc cat` a backup
   object through `mongorestore --archive --gzip` into a throwaway database and diff.
