# Runbook — the USAA savings and trip tracker on usaa-238

> **Status: PET-590.** Terraform declares the host, the database and the routes. The
> playbook `ansible/playbooks/configure-usaa.yml` installs the app.

`petedio-usaa` (private repo `PeteDio-Labs/petedio-usaa`) is a Bun app that tracks savings
and trips over the USAA bank ledger. Its source of truth is the `usaa` database on 231.
The statements and the SQLite file they were built from stay in the `usaa-statements`
bucket (see [usaa-statement-backup.md](usaa-statement-backup.md)).

## What runs where

| | |
|---|---|
| Host | `usaa-238`, LXC 238 on pve03, `192.168.50.238` (`environments/homelab/usaa.tf`) |
| Service | `usaa.service` runs `/opt/usaa/bin/petedio-usaa serve` as user `usaa` on `:8080` |
| Config | `/etc/usaa/usaa.env` (root:usaa 0640), data dir `/var/lib/usaa` (0750 usaa) |
| Database | `usaa` on postgres-rds-231, role `usaa`, password at `kv/db/usaa` field `password` |
| `usaa.pdlab.dev` | Cloudflare Access with the Authentik IdP, allow-list Pedro and Sonia |
| `usaa-feed.pdlab.dev` | no Access, one path `/api/v1/totals`, gated by the app's bearer check |

Batsy, Sonia's agent, posts totals to `usaa-feed.pdlab.dev` from outside the lab. The
bearer is `kv/services/usaa` field `batsy_bearer_token`. Every other path on that hostname
gets the tunnel's catch-all 404, and the app also refuses non-feed paths on that Host.

Postgres 231 already admits the whole LAN: `configure-postgres.yml` has one
`host all all 192.168.50.0/24 scram-sha-256` line, which covers 238. No per-host entry is
needed.

## Order

The order is load-bearing. `apply-on-merge` reads `kv/db/usaa` at plan time, and a missing
grant fails it with permission denied.

1. The Vault change (M1, `pet-590-usaa-vault-seeds`) lands first. Apply the `ci-read` grant
   on `kv/data/db/usaa` with `scripts/apply-vault-config.sh`, then run the seed scripts for
   `kv/db/usaa` (field `password`), `kv/services/usaa` (field `batsy_bearer_token`) and
   `kv/services/usaa-minio`.
2. Merge the iac PR. `apply-on-merge` creates the container, the database and role, and the
   two routes. The service does not exist yet, so both hostnames return 502 until step 4.
3. Give 238 nesting, **before the first deploy**. Terraform cannot set container features
   (Proxmox checks for `root@pam`), so `ansible/roles/lxc-features/defaults/main.yml`
   declares them and `configure-lxc-features.yml` converges them. Without `nesting=1`,
   AppArmor denies the mount namespace that `usaa.service` needs (`PrivateTmp`,
   `ProtectSystem=strict`, `ProtectHome`) and the unit fails with `226/NAMESPACE`
   (`docs/GOTCHAS.md`, "Missing `nesting=1` breaks systemd unit sandboxing"). The play never
   restarts a container: `features` takes effect only at start.

   a. Write the config. `--limit pve03` runs only that node, and the play converges every
      container there, not only 238. It exits non-zero while any container is pending a
      restart, so pass `lxc_features_allow_restart_pending=true` for this staging run:

      ```bash
      cd ansible
      ansible-playbook -i inventory/ playbooks/configure-lxc-features.yml \
        --limit pve03 -e lxc_features_allow_restart_pending=true
      ```

      The report line for 238 should read `declared=nesting=1` and
      `RESTART PENDING`.
   b. Restart the container, on pve03. 238 has no service yet, so nothing is interrupted:

      ```bash
      ssh root@192.168.50.10 'pct reboot 238'
      ```

   c. Check the RUNNING flags on pve03. `pct config 238` is not proof: it shows what the
      next start will use, not what the container runs with now.

      ```bash
      ssh root@192.168.50.10 'grep allow_nesting /var/lib/lxc/238/config'
      ```

      Expect `lxc.apparmor.allow_nesting = 1`. No output means the container is still
      running without nesting. Do not deploy until the line is there.
   d. Optionally re-run step a without the extra-var. 238 now reads `ok`. Any other
      container on pve03 that is still pending a restart keeps the play non-zero, and that
      is not a 238 fault.
4. Run the deploy from the Mac, with the app checkout at `~/petedio/usaa` or `USAA_SRC` set.
   It needs Bun 1.4.2 or later, because older Bun cannot read the app's `bun.lock`; run
   `bun upgrade` first if `bun --version` is older. The script checks this and stops.

   ```bash
   ./scripts/deploy-usaa.sh
   ```

   The script builds `dist/petedio-usaa` for Linux x86-64, checks it is an ELF, reads the
   two secrets from Vault and the `usaa_access_aud` Terraform output from the homelab state
   into a temporary extra-vars file, and runs the playbook. It stops with "apply
   petedio-iac#424 first" when the output is missing, so the iac PR must be applied before
   this step. The app uses the audience to reject an Access token issued for any other
   application in the team. The playbook ends by waiting for `GET /healthz` to return 200
   with `"db": true`; a 200 with `"db": false` fails the play, because it means the
   database is unreachable or the role or database is missing.
5. Import the ledger (next section).

If the script says a field is empty, the M1 seed has not run. Do not write the value by
hand.

## Import the ledger

The binary reads the SQLite file the statement pipeline produced and writes it to Postgres.
Run it on 238 as the service user, so it uses the same env file. Dry-run first, then write.

1. Copy the file to 238:

   ```bash
   mc cp usaa245/usaa-statements/data/usaa.db /tmp/usaa.db   # on a machine with the mc alias
   scp /tmp/usaa.db root@192.168.50.238:/var/lib/usaa/usaa.db
   ```

2. Dry-run. This writes nothing:

   ```bash
   ssh root@192.168.50.238 \
     'set -a && . /etc/usaa/usaa.env && set +a \
      && runuser -u usaa -- /opt/usaa/bin/petedio-usaa import-ledger \
           --sqlite /var/lib/usaa/usaa.db --dry-run'
   ```

   Check the output before going on:

   - The printed schema mapping names the columns you expect, and no column is reported
     unmapped.
   - The counts match 218 statements, 218 reconciled, 9,526 transactions, dated
     2020-06-23 to 2026-07-31, and each `MATCH` or `DIFF` line reads `MATCH`.
   - The `money unit` line names the unit you expect.
   - Each account's `latest statement … closing $…` line matches the closing balance printed
     on the PDF it names as `source`, in MinIO. Counts and reconciliation pass in either unit, so this
     comparison is the only check that catches a wrong `--money-unit`. A closing 100 times too
     large means the file holds cents; 100 times too small means the reverse.

3. Write, with the `--money-unit` the dry run confirmed (`dollars` or `cents`):

   ```bash
   ssh root@192.168.50.238 \
     'set -a && . /etc/usaa/usaa.env && set +a \
      && runuser -u usaa -- /opt/usaa/bin/petedio-usaa import-ledger \
           --sqlite /var/lib/usaa/usaa.db --money-unit dollars'
   ```

   The Mac can instead run `bun run scripts/import-ledger.ts` from the petedio-usaa
   checkout with the same flags, against the same `DATABASE_URL`.

Then remove every copy, on 238 and on the machine that ran `mc cp`:

```bash
ssh root@192.168.50.238 'rm -f /var/lib/usaa/usaa.db'
rm -f /tmp/usaa.db
```

The ledger is financial data. The bucket keeps the only durable copy, so a stray copy on
238 adds exposure and nothing else. Check the import landed by signing in at
`usaa.pdlab.dev` as Pedro, the only viewer with ledger access.

⚠ **Copy `usaa.db` out of the bucket with `mc cp`. Never `mc mirror --remove`.** The
`--remove` flag deletes objects absent from the source, so a half-populated local directory
becomes a deletion of the archive. See the backup runbook.

## Rotate or recover

- **Rotate the Batsy bearer.** Reseed `kv/services/usaa` (M1's script), rerun
  `./scripts/deploy-usaa.sh`, and give Batsy the new value. The env change restarts the
  service.
- **Rotate the database password.** Reseed `kv/db/usaa`, bump
  `postgres_db_password_versions["usaa"]` so Terraform applies it (`databases.tf`), then
  rerun the deploy script.
- **The service is down.** `ssh root@192.168.50.238 journalctl -u usaa -n 50`. A health
  failure with the unit up usually means a wrong `DATABASE_URL` or a missing `usaa`
  database.
