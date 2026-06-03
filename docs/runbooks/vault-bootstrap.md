# Runbook — Vault bootstrap & seed (one-time, manual)

This runbook covers the **manual, one-time operator steps** to bring the homelab
Vault at <https://192.168.50.223:8200> (LXC 223) into service: initialize, unseal,
log in, apply config-as-code, and seed secrets. Run it **once**, by hand, *after*
Terraform has created the LXC (`environments/homelab/vault.tf`) and Ansible has
installed Vault (`ansible/playbooks/configure-vault.yml` — raft storage + self-signed
TLS, started **sealed**). These steps are deliberately **not** GitOps: `vault operator
init` emits root-equivalent material exactly once and unsealing requires a human key
quorum, so neither can be safely automated or committed. Everything else about Vault
(mounts, policies, auth methods) *is* GitOps and lives in the `vault-config` Terraform
workspace — see Step 6. Linear: **PET-6** (parent) · **PET-25** (init/unseal) ·
**PET-26** (config) · **PET-27** (seed).

> [!CAUTION]
> **This document must never contain a real unseal key, root token, secret_id, or
> seeded secret value.** It is committed to a public repo (`petedio-iac`). Everything
> below is commands + `<PLACEHOLDERS>`. Real key material goes in the operator's
> **password manager**, never in git, CI logs, Slack, or a repo `.secrets/` directory.

---

## Prerequisites

- The `vault` CLI is installed locally (`vault version`).
- LXC 223 is up and reachable, and `ansible/playbooks/configure-vault.yml` has run
  (Vault installed, raft + TLS configured, service running but **sealed**).
- Proxmox container features `nesting=1,keyctl=1` are set on the node for VMID 223.
  (The `bpg/proxmox` API token **cannot** set `features{}` — the `root@pam` check —
  so this is done out-of-band by Ansible / `pct set`. See `docs/GOTCHAS.md`.)
- The Vault CA cert is available locally so the CLI can verify the self-signed TLS.
  If `environments/homelab/vault-ca.crt` doesn't exist yet, fetch it first (Step 5);
  the Ansible playbook may already `fetch` it into the workspace for you.

Export these in every shell that talks to Vault:

```bash
export VAULT_ADDR="https://192.168.50.223:8200"
export VAULT_CACERT="$(git rev-parse --show-toplevel)/environments/homelab/vault-ca.crt"
```

> [!NOTE]
> Without `VAULT_CACERT` the CLI will reject the self-signed cert with a TLS error.
> Do **not** use `-tls-skip-verify` / `VAULT_SKIP_VERIFY` — that defeats the point of
> serving Vault over TLS. Fix the cert path instead.

---

## Step 1 — Verify the install

```bash
vault status
```

Expected on a freshly-installed, never-initialized Vault:

```
Initialized     false
Sealed          true
```

If `Initialized` is already `true`, **stop** — this Vault has been bootstrapped
before. Do not re-init (it would orphan the existing storage). Skip to Step 3 (unseal)
or find the existing keys in the password manager.

---

## Step 2 — Initialize (PET-25)

```bash
vault operator init -key-shares=5 -key-threshold=3
```

This generates **5 unseal key shares** and the **initial root token**, using Shamir's
Secret Sharing: any **3 of the 5** shares can unseal Vault.

> [!CAUTION]
> **This output appears EXACTLY ONCE and can never be recovered.** It prints all 5
> unseal keys plus the initial root token to your terminal.
>
> **Immediately:**
> 1. Copy **all 5 unseal keys** and the **initial root token** into the operator's
>    **password manager** (one entry per key is ideal). Treat each share as a
>    high-value secret.
> 2. Confirm they're saved before you clear the screen or close the terminal.
> 3. **Never** paste this output into git, a commit, CI, Slack, a ticket, or a repo
>    `.secrets/` file. **Never** screenshot it.
>
> Lose the keys → Vault is permanently sealed (unrecoverable). Leak the root token →
> full compromise of every secret.

**Why this can't be GitOps / automated:** `vault operator init` returns
root-equivalent material a single time with no second chance, and unsealing is
intentionally gated behind a **human key quorum** (3 distinct holders/shares). Putting
either into Terraform, Ansible, or CI would mean committing or logging that material —
exactly what the quorum design exists to prevent. So init/unseal stays a manual
operator ritual; auto-unseal via a cloud KMS is deferred to the AWS graduation (see
*What's deferred* and PET-29).

---

## Step 3 — Unseal

Unseal by supplying **3 distinct** unseal-key shares. Run the command three times,
pasting a **different** share at each prompt:

```bash
vault operator unseal   # paste share 1 of 3
vault operator unseal   # paste share 2 of 3
vault operator unseal   # paste share 3 of 3
```

After the third share, verify:

```bash
vault status   # expect: Sealed   false
```

> [!WARNING]
> **An LXC reboot RE-SEALS Vault.** There is no auto-unseal in the homelab — after any
> restart of LXC 223 (or the Vault service), Vault comes back **sealed** and every
> consumer read fails until a human repeats this 3-share unseal. See *Reseal after
> reboot* at the bottom. (Auto-unseal via cloud KMS is deferred to AWS — PET-29.)

---

## Step 4 — Admin login

Authenticate the CLI with the **initial root token** from your password manager:

```bash
vault login <ROOT_TOKEN>
```

> [!NOTE]
> The root token is used here only to bootstrap config (Steps 5–8). It is
> root-equivalent — keep it in the password manager, not in your shell history or
> env files. Longer term, mint a least-privileged admin via the policies created in
> Step 6 and reserve the root token for break-glass.

---

## Step 5 — Commit the public CA cert

Consumers (Terraform, Ansible, CI, your laptop) need the CA cert to verify Vault's
self-signed TLS. **A certificate is public — it is NOT a secret** — so it belongs in
git (unlike the private key `/opt/vault/tls/vault.key`, which must never leave the host).

Copy the cert off the host into the workspace and commit it:

```bash
# From the repo root, pull the public cert off LXC 223:
scp root@192.168.50.223:/opt/vault/tls/vault.crt \
    environments/homelab/vault-ca.crt

git add environments/homelab/vault-ca.crt
git commit -m "Add Vault public CA cert (PET-6)"
```

Consumers then set `VAULT_CACERT=environments/homelab/vault-ca.crt` (as in
Prerequisites).

> [!NOTE]
> `ansible/playbooks/configure-vault.yml` may already `fetch` `vault.crt` into
> `environments/homelab/vault-ca.crt` automatically. If so, just `git add` / commit the
> file it produced and skip the `scp`. Commit **only** `vault.crt` — never `vault.key`.

---

## Step 6 — Apply Vault config-as-code (PET-26)

From here on, Vault's *configuration* is GitOps. The `vault-config` Terraform workspace
declares the KV mount, policies, AppRole auth, and the GitHub OIDC role. Apply it once
by hand here using the root token; subsequent changes go through the normal PR →
`plan` → merge → `apply` flow.

```bash
cd environments/homelab/vault-config
export VAULT_TOKEN="<ROOT_TOKEN>"     # from the password manager (NOT committed)
terraform init
terraform apply
```

> [!NOTE]
> `vault-config` is a **separate** Terraform workspace from `environments/homelab`
> (which manages the LXCs and uses the MinIO S3 backend — see `backend.tf`). It is
> applied with the **root token**, not the Proxmox/MinIO creds. If the workspace
> doesn't exist yet, it is being authored in parallel under PET-26; the resources it
> creates are the mount/policies/auth methods listed below.

Verify the config landed:

```bash
vault secrets list   # expect a kv-v2 mount at kv/
vault policy list     # expect the policies the workspace defines (e.g. ansible, terraform-local, …)
vault auth list       # expect approle/ and the GitHub OIDC (jwt/) method
```

---

## Step 7 — Seed secrets (PET-27)

With the `kv/` mount in place, seed the initial secrets. The commands below use
**`vault kv put`** with **placeholder** values — substitute real values at run time;
**do not commit real values**.

> [!NOTE]
> **Source of truth for the real values:** they are decrypted from the **old
> `homelab-infra` repo's `ansible-vault` files**, e.g.
> `ansible-vault view group_vars/all/vault.yml` (needs Pedro's interactive vault
> password). Copy each value straight from `ansible-vault view` output into the
> corresponding `vault kv put` — never write it to disk in between.

### What to seed

| KV path                 | Keys                                          | Source (old `homelab-infra` ansible-vault) |
|-------------------------|-----------------------------------------------|--------------------------------------------|
| `kv/iac/proxmox`        | `api_token`                                   | Proxmox API token for `bpg/proxmox`        |
| `kv/iac/minio`          | `access_key`, `secret_key`                    | MinIO creds (TF S3 state + S3-compat)      |
| `kv/iac/lxc-ssh`        | `public_key`, `private_key`                   | SSH keypair TF installs into LXCs          |
| `kv/poker/db`           | `DATABASE_URL`, `admin_password`, `poker_password` | Postgres admin + `poker` role creds   |
| `kv/services/qbittorrent` | `username`, `password`                      | media stack                                |
| `kv/services/authentik` | `secret_key`, `bootstrap_token`               | auth                                        |
| `kv/services/cloudflare`| `tunnel_token`                                | Cloudflare tunnel                          |
| `kv/services/nexus`     | `admin_password`                              | registry                                   |

### Example commands (placeholders only)

```bash
# --- IaC platform creds ---
vault kv put kv/iac/proxmox \
    api_token="<PROXMOX_API_TOKEN>"

vault kv put kv/iac/minio \
    access_key="<MINIO_ACCESS_KEY>" \
    secret_key="<MINIO_SECRET_KEY>"

# Read the private key from a temp file to avoid it landing in shell history;
# delete the temp file immediately after.
vault kv put kv/iac/lxc-ssh \
    public_key="<LXC_SSH_PUBLIC_KEY>" \
    private_key=@/tmp/lxc_ssh_key && rm -f /tmp/lxc_ssh_key

# --- Poker app DB ---
# DATABASE_URL format (sslmode=disable — Postgres on 231 is plain TCP on the LAN):
#   postgresql://poker:<poker_password>@192.168.50.231:5432/poker?sslmode=disable
vault kv put kv/poker/db \
    DATABASE_URL="postgresql://poker:<POKER_PASSWORD>@192.168.50.231:5432/poker?sslmode=disable" \
    admin_password="<POSTGRES_ADMIN_PASSWORD>" \
    poker_password="<POKER_PASSWORD>"

# --- Homelab services ---
vault kv put kv/services/qbittorrent username="<QBT_USER>" password="<QBT_PASSWORD>"
vault kv put kv/services/authentik    secret_key="<AUTHENTIK_SECRET_KEY>" bootstrap_token="<AUTHENTIK_BOOTSTRAP_TOKEN>"
vault kv put kv/services/cloudflare   tunnel_token="<CLOUDFLARE_TUNNEL_TOKEN>"
vault kv put kv/services/nexus        admin_password="<NEXUS_ADMIN_PASSWORD>"
```

> [!CAUTION]
> Keep `<POKER_PASSWORD>` identical in `DATABASE_URL` and in `poker_password` — they
> must match the password the Postgres `poker` role was created with (and
> `TF_VAR_poker_db_password`), or app/provider connections fail.

Spot-check (metadata only — avoid printing values to the terminal where practical):

```bash
vault kv list kv/iac
vault kv list kv/services
vault kv get -field=DATABASE_URL kv/poker/db   # sanity-check format only
```

---

## Step 8 — Provision AppRole creds for consumers

The `ansible` and `terraform-local` AppRoles were created by the `vault-config` apply
(Step 6). Each consumer authenticates with a **role_id** (non-secret, stable) plus a
**secret_id** (secret, generated here). Mint a secret_id per consumer and store it
**operator-side** under `iac/.secrets/` — which is **gitignored and never committed**.

> [!CAUTION]
> Confirm `iac/.secrets/` is in `.gitignore` **before** writing anything there. These
> files contain live credentials. They never get committed, pushed, or pasted anywhere.

```bash
# --- ansible AppRole ---
vault read  auth/approle/role/ansible/role-id            # copy role_id (not secret)
vault write -f auth/approle/role/ansible/secret-id       # generates a fresh secret_id

# Persist operator-side (gitignored). Example layout:
#   iac/.secrets/ansible.role_id
#   iac/.secrets/ansible.secret_id

# --- terraform-local AppRole (repeat the same two reads/writes) ---
vault read  auth/approle/role/terraform-local/role-id
vault write -f auth/approle/role/terraform-local/secret-id
```

> [!NOTE]
> `secret_id`s are rotatable: re-run `write -f .../secret-id` to mint a new one and
> revoke the old. CI does **not** use these AppRole files — it will authenticate via the
> **GitHub OIDC** (`jwt/`) role once that cutover happens (deferred — see below).

---

## Step 9 — Verify a consumer read (least-privilege proof)

Prove an AppRole can **read** the secrets it needs and **cannot write** — i.e. the
policy is correctly least-privileged. Log in with the `ansible` role_id + secret_id from
Step 8 and exercise `kv/poker/db`:

```bash
# Log in via AppRole; capture only the resulting token.
VAULT_TOKEN="$(vault write -field=token auth/approle/login \
    role_id="<ANSIBLE_ROLE_ID>" \
    secret_id="<ANSIBLE_SECRET_ID>")"
export VAULT_TOKEN

# READ should SUCCEED:
vault kv get kv/poker/db

# WRITE should be DENIED (proves the policy is read-only on this path):
vault kv put kv/poker/db poker_password="should-be-denied"
#  → expect: "permission denied" (403). If this SUCCEEDS, the policy is too broad —
#    fix it in the vault-config workspace (Step 6) before going live.
```

When done, drop the scoped token from your shell (`unset VAULT_TOKEN`) so you don't
keep operating as the consumer.

---

## Reseal after reboot

Vault is **not** auto-unsealed in the homelab. After **any** reboot of LXC 223 or
restart of the Vault service, Vault comes back **sealed** and all consumer reads fail
until a human repeats the unseal:

```bash
export VAULT_ADDR="https://192.168.50.223:8200"
export VAULT_CACERT="$(git rev-parse --show-toplevel)/environments/homelab/vault-ca.crt"
vault operator unseal   # ×3, distinct shares from the password manager
vault status            # expect Sealed=false
```

You do **not** re-init and you do **not** re-seed — storage (raft) and secrets persist
across reboots. Only the unseal is needed.

---

## What's deferred

- **CI OIDC cutover** — moving CI off any static creds onto the GitHub OIDC (`jwt/`)
  Vault role created in Step 6, so the runner gets short-lived tokens with no stored
  secret_id.
- **Proxmox API token rotation** — rotating the seeded `kv/iac/proxmox` token and
  wiring rotation into the workflow.
- **Auto-unseal** — replacing the manual 3-share unseal with cloud-KMS auto-unseal at
  AWS graduation, so reboots no longer require a human quorum. Tracked in **PET-29**.
