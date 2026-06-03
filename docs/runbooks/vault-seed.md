# Runbook — Seed bootstrap secrets into Vault KV (PET-27)

This runbook covers the **manual, one-time operator steps** to seed the initial
secret **values** into the homelab Vault KV-v2 store at
<https://192.168.50.223:8200> (LXC 223), and to provision the AppRole credentials
that local Ansible/Terraform consumers use to read them.

It is the operator-run companion to the config-as-code in
`environments/homelab/vault-config/` (the `kv` mount, `policies.tf`, and the
AppRole + GitHub-OIDC auth in `auth.tf`), which is already applied. The Vault
*bootstrap* (init / unseal / config apply) is covered by
[`vault-bootstrap.md`](./vault-bootstrap.md) — read that first; this runbook
assumes Vault is **unsealed**, the `kv` mount and policies exist, and you hold the
root/bootstrap token. Linear: **PET-6** (parent) · **PET-27** (seed).

> [!CAUTION]
> **This document must never contain a real secret value, token, secret_id, or
> private key.** It is committed to a public repo (`petedio-iac`). Everything below
> is commands + `<PLACEHOLDERS>`. Real values come from the old `homelab-infra`
> ansible-vault files or Pedro's password manager (see *Source mapping*), are
> entered interactively at run time, and go **only** into Vault — never into git, CI
> logs, Slack, a ticket, or a tracked repo file. AppRole `secret_id`s are written to
> the **gitignored** `iac/.secrets/` only.

> [!NOTE]
> **Two ways to run the seed.** Either (a) paste each `vault kv put` from
> *What to seed* by hand, substituting real values, or (b) use the helper
> `scripts/vault-seed.sh`, which prompts for each value via `read -s` (no echo, no
> disk) and never logs it. The script is the recommended path — it is idempotent and
> cannot accidentally print a value. Verify afterward with `scripts/vault-verify.sh`.

---

## Prerequisites

- Vault is **unsealed** and reachable; the `kv` mount, the `ci-read` / `terraform` /
  `ansible` policies, and the AppRole + JWT auth backends already exist (PET-25/26 —
  see `vault-bootstrap.md`, applied from `environments/homelab/vault-config/`).
- The `vault` CLI is installed locally (`vault version`).
- The Vault public CA cert is present at `environments/homelab/vault-ca.crt` (it is —
  committed). Consumers need it to verify the self-signed TLS.

Export these in **every** shell that talks to Vault (run from the repo root):

```bash
export VAULT_ADDR="https://192.168.50.223:8200"
export VAULT_CACERT="$(pwd)/environments/homelab/vault-ca.crt"
```

> [!NOTE]
> Without `VAULT_CACERT` the CLI rejects the self-signed cert with a TLS error. Do
> **not** use `-tls-skip-verify` / `VAULT_SKIP_VERIFY`. If you are not at the repo
> root, point `VAULT_CACERT` at the absolute path of `vault-ca.crt`. (Inside a git
> checkout, `VAULT_CACERT="$(git rev-parse --show-toplevel)/environments/homelab/vault-ca.crt"`
> also works.)

Authenticate the CLI with the **root/bootstrap token** from the password manager
(same token used in `vault-bootstrap.md` Step 4/6). Either:

```bash
vault login        # paste the root/bootstrap token at the prompt (not echoed)
```

…or, for the helper scripts, export it (kept out of shell history — note the leading
space, and a shell with `HISTCONTROL=ignorespace`):

```bash
 export VAULT_TOKEN="<ROOT_OR_BOOTSTRAP_TOKEN>"
```

> [!NOTE]
> The root token is root-equivalent — used here only to seed. Keep it in the password
> manager, not in env files or committed anywhere. Drop it from the shell
> (`unset VAULT_TOKEN`) when the seed is done.

---

## Source mapping — where each value comes from

The real values originate from **two** places:

1. **The old `homelab-infra` repo's `ansible-vault` files** — NOT on this Mac (the
   Mac-only workspace can't reach the old SMB mount). Clone and decrypt them:

   ```bash
   git clone https://github.com/PeteDio-Labs/homelab-infra
   cd homelab-infra
   git checkout feat/g25-tf-imports
   # View a vault file interactively (prompts for the ansible-vault password —
   # Pedro has it; it is NOT the Vault token):
   ansible-vault view infrastructure/ansible/vars/<file>.vault.yml
   ```

   > [!NOTE]
   > Exact paths/filenames in `homelab-infra` may differ slightly from the table
   > below (the old repo predates this layout). If a file isn't where listed, grep the
   > clone: `grep -rl "proxmox\|minio\|qbittorrent" --include="*vault*.yml" .` and
   > decrypt the match. Copy each value **straight from the `ansible-vault view`
   > output into the prompt / `vault kv put`** — never write it to an intermediate
   > plaintext file. If you must stage the SSH private key as a file, use a path under
   > `iac/.secrets/` (gitignored) and `shred`/`rm -f` it immediately after.

2. **Pedro's password manager / the manual Postgres standup.** `kv/poker/db`
   `admin_password` and `poker_password` were **set by Pedro during the manual
   Postgres standup** (LXC 231, PG 17.10, role `poker`) — they are **not** in
   `homelab-infra`. Get them from the password manager. `DATABASE_URL` is *derived*
   (it embeds `poker_password`).

| KV path                   | Keys                                                 | Source                                                                  |
|---------------------------|------------------------------------------------------|-------------------------------------------------------------------------|
| `kv/iac/proxmox`          | `api_token`                                          | `homelab-infra` → `terraform.vault.yml` (Proxmox API token for `bpg/proxmox`) |
| `kv/iac/minio`            | `access_key`, `secret_key`                           | `homelab-infra` → `minio-terraform-state.vault.yml` (TF S3 state + S3-compat) |
| `kv/iac/lxc-ssh`          | `public_key`, `private_key`                          | `homelab-infra` → the SSH keypair TF installs into LXCs                  |
| `kv/poker/db`             | `DATABASE_URL`, `admin_password`, `poker_password`   | **Password manager** — set at the manual Postgres standup (LXC 231)     |
| `kv/services/qbittorrent` | `username`, `password`                               | `homelab-infra` → `qbittorrent.vault.yml`                               |
| `kv/services/authentik`   | `secret_key`, `bootstrap_token`                      | `homelab-infra` → authentik creds vault file                            |
| `kv/services/cloudflare`  | `tunnel_token`                                       | `homelab-infra` → cloudflare tunnel vault file                          |
| `kv/services/nexus`       | `admin_password`                                     | `homelab-infra` → nexus creds vault file (or password manager)          |

---

## What to seed — exact commands (placeholders only)

These mirror `scripts/vault-seed.sh`. Each `vault kv put` writes one KV-v2 entry at
`kv/<path>` (the provider/CLI maps that to `kv/data/<path>` internally — see the
policy note at the bottom). Substitute the real value for each `<PLACEHOLDER>` at run
time; **commit none of them**.

```bash
# --- IaC platform creds ---
vault kv put kv/iac/proxmox \
    api_token="<PROXMOX_API_TOKEN>"

vault kv put kv/iac/minio \
    access_key="<MINIO_ACCESS_KEY>" \
    secret_key="<MINIO_SECRET_KEY>"

# Stage the SSH private key as a file ONLY under the gitignored iac/.secrets/, then
# shred it. `@file` reads the value from the file so the key never lands in history.
vault kv put kv/iac/lxc-ssh \
    public_key="<LXC_SSH_PUBLIC_KEY>" \
    private_key=@iac/.secrets/lxc_ssh_key
shred -u iac/.secrets/lxc_ssh_key 2>/dev/null || rm -f iac/.secrets/lxc_ssh_key

# --- Poker app DB ---
# DATABASE_URL is EXACTLY (sslmode=disable — Postgres on .231 is plain TCP on the LAN):
#   postgresql://poker:<poker_password>@192.168.50.231:5432/poker?sslmode=disable
# <POKER_PASSWORD> here MUST equal poker_password below and the password the Postgres
# `poker` role was created with (and TF_VAR_poker_db_password), or connections fail.
vault kv put kv/poker/db \
    DATABASE_URL="postgresql://poker:<POKER_PASSWORD>@192.168.50.231:5432/poker?sslmode=disable" \
    admin_password="<POSTGRES_ADMIN_PASSWORD>" \
    poker_password="<POKER_PASSWORD>"

# --- Homelab services ---
vault kv put kv/services/qbittorrent \
    username="<QBT_USERNAME>" \
    password="<QBT_PASSWORD>"

vault kv put kv/services/authentik \
    secret_key="<AUTHENTIK_SECRET_KEY>" \
    bootstrap_token="<AUTHENTIK_BOOTSTRAP_TOKEN>"

vault kv put kv/services/cloudflare \
    tunnel_token="<CLOUDFLARE_TUNNEL_TOKEN>"

vault kv put kv/services/nexus \
    admin_password="<NEXUS_ADMIN_PASSWORD>"
```

> [!CAUTION]
> Keep `<POKER_PASSWORD>` **identical** in `DATABASE_URL` and in `poker_password`.
> They must match the Postgres `poker` role's password (and `TF_VAR_poker_db_password`)
> or app/provider connections fail. `admin_password` is the Postgres **admin/superuser**
> password, a different value.

### Recommended: run the helper instead

```bash
# Prompts (no echo) for each value and runs the puts; idempotent, never logs values.
./scripts/vault-seed.sh
```

`scripts/vault-seed.sh` will read a value from a matching env var if already exported
(e.g. `PROXMOX_API_TOKEN`), otherwise prompt with `read -s`. See its header for the
full env-var list.

---

## Provision AppRole creds for consumers (local Ansible / Terraform)

The `ansible` and `terraform-local` AppRoles were created by the `vault-config` apply
(see `auth.tf`). Each consumer authenticates with a **role_id** (non-secret, stable)
plus a **secret_id** (secret, minted here). Persist them **operator-side** under
`iac/.secrets/`, which is **gitignored** (`.gitignore` → `.secrets/`).

> [!CAUTION]
> Confirm `iac/.secrets/` is gitignored **before** writing anything there. `git status`
> must show nothing under it. These files hold live credentials — never commit, push,
> or paste them anywhere.

```bash
# Create the gitignored secrets dir if it doesn't exist yet.
mkdir -p iac/.secrets && chmod 700 iac/.secrets

# --- ansible AppRole (role_name "ansible") ---
vault read  -field=role_id  auth/approle/role/ansible/role-id   > iac/.secrets/ansible.role_id
vault write -f -field=secret_id auth/approle/role/ansible/secret-id > iac/.secrets/ansible.secret_id

# --- terraform-local AppRole (role_name "terraform-local") ---
vault read  -field=role_id  auth/approle/role/terraform-local/role-id   > iac/.secrets/terraform-local.role_id
vault write -f -field=secret_id auth/approle/role/terraform-local/secret-id > iac/.secrets/terraform-local.secret_id

chmod 600 iac/.secrets/*.role_id iac/.secrets/*.secret_id
```

> [!NOTE]
> `secret_id`s are rotatable: re-run the `write -f .../secret-id` to mint a fresh one
> (the old one keeps working until its TTL/use limit or you revoke it). CI does **not**
> use these AppRole files — it authenticates via the **GitHub OIDC** (`jwt-github`)
> role once the CI cutover lands (deferred — PET-29).

---

## Verification

Run the verifier — it checks presence of every seeded key (never printing a value),
then does an AppRole login and a consumer read of `kv/poker/db` `DATABASE_URL`:

```bash
./scripts/vault-verify.sh
```

It prints `PASS` / `FAIL` per check. All PASS ⇒ the AC is met:

> `vault kv get` returns each entry; a consumer reads `kv/poker/db` `DATABASE_URL`
> via the AppRole.

Manual spot-check equivalents (metadata / presence only — avoid dumping values):

```bash
vault kv list kv/iac
vault kv list kv/services
vault kv list kv/poker
# Confirm a field exists without printing it (length only):
vault kv get -field=DATABASE_URL kv/poker/db | wc -c   # >0 ⇒ present
```

To prove **least-privilege** (the consumer can read but not write) — log in with the
`ansible` AppRole and confirm a write is denied:

```bash
ROLE_ID="$(cat iac/.secrets/ansible.role_id)"
SECRET_ID="$(cat iac/.secrets/ansible.secret_id)"
VAULT_TOKEN="$(vault write -field=token auth/approle/login \
    role_id="$ROLE_ID" secret_id="$SECRET_ID")"
export VAULT_TOKEN

vault kv get kv/iac/proxmox            # READ should SUCCEED (ansible policy: kv/data/iac/*)
vault kv put kv/iac/proxmox api_token=x  # WRITE should be DENIED (403 permission denied)

unset VAULT_TOKEN   # drop the scoped token; re-auth as operator if continuing
```

> [!NOTE]
> The `ansible` policy grants `kv/data/iac/*` and `kv/data/services/*` (read) — **not**
> `kv/poker/*`. So the *consumer read of `kv/poker/db`* in `vault-verify.sh` uses the
> **`terraform-local`** AppRole (policy `terraform` grants `kv/data/poker/*`), which is
> the path PET-32/PET-12 actually exercise. See the policy map below.

---

## Policy ↔ seed-path map (reference)

KV v2 splits the API: values live under `kv/data/<path>`, listing/metadata under
`kv/metadata/<path>`. Policies (`policies.tf`) are written against those. The seed
paths and who can read them:

| Seed path (`kv/<path>`)   | `ci-read` (GitHub OIDC) | `terraform` (local/CI TF) | `ansible` (host config) |
|---------------------------|-------------------------|---------------------------|-------------------------|
| `kv/iac/proxmox`          | ✅ explicit             | ✅ `iac/*`                | ✅ `iac/*`              |
| `kv/iac/minio`            | ✅ explicit             | ✅ `iac/*`                | ✅ `iac/*`              |
| `kv/iac/lxc-ssh`          | ✅ explicit             | ✅ `iac/*`                | ✅ `iac/*`              |
| `kv/poker/db`             | ✅ `poker/*`            | ✅ `poker/*`              | ❌ (by design)         |
| `kv/services/*`           | ❌ (by design)         | ❌ (by design)           | ✅ `services/*`        |

- **PET-29 CI** uses `ci-read` → needs `kv/iac/{proxmox,minio,lxc-ssh}` → all three are
  **explicitly** granted. ✅
- **PET-32 / PET-12** read `kv/poker/db` → both `ci-read` and `terraform` grant
  `kv/data/poker/*`. ✅
- The two "❌ by design" cells are intentional least-privilege: CI/TF don't need
  homelab service creds; Ansible doesn't need the poker DB creds. No policy change
  required for this seed.

---

## What's deferred

- **CI OIDC cutover** (PET-29) — CI moves off any static creds onto the `jwt-github`
  role minted in `vault-config`; the runner gets short-lived `ci-read` tokens with no
  stored `secret_id`. The AppRole files above are for **local** Ansible/TF only.
- **Proxmox API token rotation** — rotating the seeded `kv/iac/proxmox` token.
- **Auto-unseal** — replacing the manual 3-share unseal at AWS graduation (PET-29).
