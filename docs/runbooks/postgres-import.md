# Runbook — adopt the live `poker` Postgres db/role under Terraform (import-before-apply)

This runbook covers the **manual, one-time operator steps** to bring the **already-live**
`poker` database, its owning login role, and its `ALL`-privileges grant — on
postgres-rds (LXC 231, `192.168.50.231:5432`, PG 17.10) — under management of the
`cyrilgdn/postgresql` provider **without recreating them**. Linear: **PET-32**.

These objects were created **manually** (and verified — scram over plain TCP) before
they were modelled in Terraform. They are **not** in Terraform state yet:
`environments/homelab/postgres.tf` gates `module.poker_db` on `var.postgres_ready`, and
until PET-32 the gate was `false` (`count = 0`), so TF never knew about them. PET-32
flips the default to `true` (`count = 1`). The first thing the operator does after that
flip **must** be an `import` — never an `apply`.

> [!CAUTION]
> **`terraform import` rewrites the SHARED MinIO state. `terraform apply` mutates the
> LIVE database.** This is a single-operator procedure on a backend with **no state
> locking** (MinIO doesn't speak DynamoDB — see `environments/homelab/backend.tf`).
> Ensure **no concurrent apply** can run while you work: do this **before** the PET-32
> PR merges, so CI's apply-on-merge cannot fire mid-procedure. Never paste a real
> secret into a terminal that logs, into CI, or into this repo (it is public).

---

## Why import first (do not skip this)

`cyrilgdn/postgresql` is **not** declarative-by-reconciliation for pre-existing objects:
if `module.poker_db` has `count = 1` but the objects aren't in state, `terraform apply`
plans to **create** `postgresql_role.owner` and `postgresql_database.this` from scratch.
Against the live host that is **destructive / failing**:

- `postgresql_role "poker"` → the role already exists → apply **errors** `role "poker"
  already exists` (best case), or churns ownership/attributes.
- `postgresql_database "poker"` → the db already exists → apply **errors** `database
  "poker" already exists`; with the database name as its identity, a mismatch can also
  surface as a **destroy-and-recreate** of the live db in the plan — i.e. **data loss**.

Importing writes the live objects into state **first**, so the subsequent plan is a
diff against reality (ideally empty) instead of a create-from-nothing.

> [!WARNING]
> At provider `~> 1.0`, `postgresql_role` and `postgresql_database` have **no `Update`
> in the classic sense** for several attributes — a divergence can force
> **destroy/recreate**. Any `destroy` or `recreate` in the plan after import is a
> **STOP-and-reassess** (see "Lockstep ordering"). Never auto-approve through it.

---

## Resource addresses & import IDs

The objects live in `modules/postgres-db/main.tf`, instantiated as `module.poker_db`
(`count = 1`, so index `[0]`). Import-ID formats verified against the cyrilgdn provider
docs/source at tag **v1.22.0** (within the pinned `~> 1.0`):

| Resource address (TF)                          | Live object        | Importable in `~> 1.0`? | Import ID  |
|------------------------------------------------|--------------------|-------------------------|------------|
| `module.poker_db[0].postgresql_role.owner`     | login role `poker` | **Yes** (ID = role name)| `poker`    |
| `module.poker_db[0].postgresql_database.this`  | database `poker`   | **Yes** (ID = db name)  | `poker`    |
| `module.poker_db[0].postgresql_grant.owner_all`| `ALL` on db `poker`| **No** — no `Importer`  | _n/a, see below_ |

> [!NOTE]
> `postgresql_grant` defines **no `Importer`** at v1.x (`resource_postgresql_grant.go`
> has only Create/Read/Delete — no `schema.ResourceImporter`). `terraform import` of it
> would fail `resource postgresql_grant doesn't support import`. We therefore do **not**
> import the grant; we let `apply` **create the state entry** for it. Because the live
> role already holds `ALL` on the live db, the grant's Create is **idempotent on the
> database** — it adds the object to *state* but is a **no-op on Postgres**. This is the
> safe, provider-supported path; see "Step 3".

---

## Preconditions

- **PET-27 has seeded `kv/poker/db`** in the live Vault with keys `DATABASE_URL`,
  `admin_password`, `poker_password` (see `docs/runbooks/vault-bootstrap.md` §"What to
  seed"). The TF config reads `admin_password` (→ the `postgresql` provider password)
  and `poker_password` (→ the `poker` owner role) from this entry.
- **PET-29 is merged to `main`** (Vault provider + OIDC wiring + the resolver locals in
  `postgres.tf`). This PR (PET-32) **stacks on PET-29** and must merge **after** it.
- **This branch checked out** (`pet-32-postgres-cyrilgdn`): it sets `postgres_ready`'s
  default to `true`, so `module.poker_db` has `count = 1` and the three addresses above
  exist in config.
- **Postgres is live & reachable**: `192.168.50.231:5432`, db `poker` + role `poker` +
  the `ALL` grant present and verified.
- **Operator has a Vault env** (the resolver locals read Vault at plan/refresh because
  the gate is now open):
  ```bash
  export VAULT_ADDR="https://192.168.50.223:8200"
  export VAULT_CACERT="$(git rev-parse --show-toplevel)/environments/homelab/vault-ca.crt"
  export VAULT_TOKEN="<a token, or use an AppRole login>"   # never commit / echo to logs
  ```
  (AppRole alternative: `vault write auth/approle/login role_id=… secret_id=…` then
  export the returned token. See `vault-bootstrap.md` Step 8.)
- **Operator has the MinIO backend creds** for the real S3 state backend:
  ```bash
  export AWS_ACCESS_KEY_ID="<minio access_key>"
  export AWS_SECRET_ACCESS_KEY="<minio secret_key>"
  ```
- **Single operator, NO concurrent applies.** The backend has no locking; bucket
  versioning is the only safety net. Confirm CI is not mid-apply and this PR is **not
  yet merged**.

> [!NOTE]
> The `poker`/`admin` passwords default to `null` and resolve from Vault via the
> `local.poker_db_password` / `local.postgres_admin_password` resolvers in
> `postgres.tf`. If Vault is briefly unavailable you may break-glass with
> `TF_VAR_postgres_admin_password` / `TF_VAR_poker_db_password` (they take precedence),
> but the normal path is Vault — do **not** put real values on the command line.

---

## Procedure

Run everything from `environments/homelab` on this branch, against the **real MinIO
backend** (the same `backend.tf` CI uses — do **not** use a local/override backend, or
you'll import into throwaway state).

### Step 0 — sanity, on the live DB (read-only)

Confirm the objects exist exactly as modelled (so import IDs are right):

```bash
# DATABASE_URL is the poker-role URL; for admin checks use the admin role.
psql "$(vault kv get -field=DATABASE_URL kv/poker/db)" -c '\conninfo'
psql "$(vault kv get -field=DATABASE_URL kv/poker/db)" -c \
  "SELECT rolname FROM pg_roles WHERE rolname='poker';
   SELECT datname FROM pg_database WHERE datname='poker';"
```

Expect one `poker` role and one `poker` database. (Reading `DATABASE_URL` to a
variable/`psql` is fine; avoid printing the value itself.)

### Step 1 — `terraform init` against the real backend

```bash
terraform init
```

Initializes the MinIO S3 backend and downloads the pinned providers (`cyrilgdn/postgresql
~> 1.0`, `hashicorp/vault ~> 4.0`, `bpg/proxmox ~> 0.66`).

### Step 2 — import the role and the database (NOT the grant)

`postgres_ready` already defaults to `true` on this branch, so the gate is open and the
addresses resolve. (`-var postgres_ready=true` is shown for belt-and-suspenders; it is
redundant given the default and may be omitted.)

```bash
terraform import 'module.poker_db[0].postgresql_role.owner'    poker
terraform import 'module.poker_db[0].postgresql_database.this' poker
# If you want to be explicit about the gate:
#   terraform import -var postgres_ready=true 'module.poker_db[0].postgresql_role.owner'    poker
#   terraform import -var postgres_ready=true 'module.poker_db[0].postgresql_database.this' poker
```

> [!CAUTION]
> Do **not** run `terraform import … postgresql_grant.owner_all …` — the resource has no
> importer and the command will fail. The grant is handled in Step 3.

Each import should report `Import successful!`. If `import` says the role/db **doesn't**
exist, STOP — your provider connection (admin creds / host) is wrong; fix it before
proceeding (an apply now would create duplicates or fail).

### Step 3 — plan, and confirm 0 to destroy

```bash
terraform plan -out tf.plan
```

**Read the plan content — do not trust a green exit code or an empty CI comment**
(lesson learned, PET-19: `plan | tee` greenwashing; always read the plan body). Expect:

- **`postgresql_role.owner`** and **`postgresql_database.this`**: **no changes** (they
  were just imported and match the live objects). A small in-place `~` on the role
  (e.g. a password attribute Postgres won't echo back) may appear — acceptable **only**
  if it's in-place and matches the Vault-sourced value; investigate anything else.
- **`postgresql_grant.owner_all`**: the **only** resource **to add** (`+`). This is
  expected — the grant isn't importable, so apply will materialize its **state entry**.
  It is a **no-op on the live database** (the role already has `ALL`).
- **Plan summary must read `X to add, Y to change, 0 to destroy`** with the **add ≤ 1**
  (just the grant) and **`0 to destroy`**.

> [!WARNING]
> **Any `destroy`, or any plan that would recreate `postgresql_database.this` /
> `postgresql_role.owner`, is a STOP.** Do not merge, do not apply. Re-check that the
> imports landed (`terraform state list`), the IDs were `poker`, and the provider is
> pointed at `192.168.50.231` as the right admin role. Reassess before going further.

### Step 4 — lockstep: merge so CI applies the in-sync state

The state now contains the role + db; the only pending change is the idempotent grant.

1. With the clean plan from Step 3 in hand (`0 to destroy`, ≤ 1 add = the grant),
   **merge this PR** (after PET-29). CI's apply-on-merge then runs `terraform apply`
   from the **same shared state** you just imported into and creates the grant's state
   entry as a no-op on the DB.
2. Alternatively, if you prefer to close the loop locally first, apply the saved plan
   yourself **before** merge — but only with an explicit human review of `tf.plan`:
   ```bash
   terraform apply tf.plan      # OPERATOR-ONLY; never -auto-approve here
   ```
   Then merge; CI's apply becomes a no-op (state already converged).

> [!CAUTION]
> **Ordering is the whole point.** Import into the shared state **first** → confirm `0
> to destroy` → **then** let any `apply` (CI or local) run. **Never** let an apply with
> `postgres_ready=true` execute **before** the import — it would try to recreate the
> live db/role. If this PR somehow merges before the import, the apply will fail on
> "already exists" (or worse); pause CI, perform the imports against the shared state,
> then re-run.

---

## Verification (done = all of these pass)

```bash
# 1) State holds the three resources (role, database, grant) after apply:
terraform state list | grep poker_db
#   module.poker_db[0].postgresql_database.this
#   module.poker_db[0].postgresql_grant.owner_all
#   module.poker_db[0].postgresql_role.owner

# 2) A fresh plan is clean — no drift, nothing to do:
terraform plan        # expect: "No changes. Your infrastructure matches the configuration."

# 3) The app/DB still connects with the Vault-sourced URL:
psql "$(vault kv get -field=DATABASE_URL kv/poker/db)" -c '\conninfo'
```

> [!NOTE]
> Between Step 3 (grant pending) and Step 4 (grant applied), `state list` shows only the
> role + database (2 entries). After the apply it shows all **3**. The final `terraform
> plan` is the real gate: it must report **no changes**.

---

## Rollback / recovery

- **Imported the wrong ID, or want to redo cleanly:** `terraform state rm
  'module.poker_db[0].postgresql_role.owner'` (and `.postgresql_database.this`) removes
  them from **state only** — it does **not** touch the live DB — then re-import. Confirm
  via Step 0 first.
- **Backend state got into a bad shape:** MinIO bucket `tfstate` has **versioning on**
  (`backend.tf`); restore the prior `homelab/terraform.tfstate` object version. Then
  re-run the procedure.
- **An apply ran before import and errored:** the live db/role are unharmed by an
  "already exists" failure (it aborts before mutating). Pause CI, do the imports against
  the shared state, re-plan to `0 to destroy`, then re-apply.
