# petedio-iac

Greenfield Terraform + Ansible for the PeteDio homelab→AWS migration. Built
AWS-shaped so graduating to real AWS is a provider/endpoint/variable swap, not a
rewrite. Linear project: **Platform** (`PET-<n>`).

## Layout

```
environments/homelab/   # current target — Proxmox / MinIO state backend
  backend.tf            # s3 backend -> fresh MinIO (.221, bucket tfstate, versioned)
  providers.tf          # bpg/proxmox (token auth, ssh agent)
  variables.tf
  runner.tf             # self-hosted GitHub Actions runner (LXC 232)
  canary.tf             # disposable proof container (LXC 250)
modules/                # (to come) proxmox-vm, proxmox-lxc, s3-bucket, postgres-db, ...
ansible/                # host config (runner registration, LXC features)
docs/GOTCHAS.md         # hard-won bpg/MinIO/runner patterns — READ THIS
.github/workflows/terraform.yml   # Workflow B: plan-on-PR, apply-on-merge
```

## Workflow B (CONVENTIONS §4)

1. Branch `pedelgadillo/pet-<n>-<slug>` off `main` (Linear's branch name).
2. **On PR:** `init` · `fmt -check` · `validate` · `plan` (posted as a PR comment) —
   the plan **is** the review surface. Runs on the self-hosted runner.
3. **On merge to `main` (squash):** `terraform apply -auto-approve`.
4. Linear `PET-<n>` rides Todo → In Progress (PR) → Done (merge).

State in MinIO S3 (no lock; versioning is the net). **Never run concurrent applies.**

## Running locally

```bash
cd environments/homelab
export AWS_ACCESS_KEY_ID=...        # MinIO access key (.221)
export AWS_SECRET_ACCESS_KEY=...    # MinIO secret key
cp terraform.tfvars.example terraform.tfvars   # fill in token + ssh key (gitignored)
terraform init
terraform plan
```

## Secrets (CI)

CI gets its creds from **HashiCorp Vault via GitHub OIDC** (PET-29). The workflow
mints a GitHub Actions OIDC token (`permissions: id-token: write`), and
`hashicorp/vault-action` exchanges it (JWT auth, role `github-actions` on the
`jwt-github` backend) for a short-lived Vault token, then exports the backend +
provider env from KV v2:

| Vault path (`kv/data/…`) | key | env exported |
|---|---|---|
| `iac/minio` | `access_key` | `AWS_ACCESS_KEY_ID` |
| `iac/minio` | `secret_key` | `AWS_SECRET_ACCESS_KEY` |
| `iac/proxmox` | `api_token` | `TF_VAR_proxmox_api_token` |
| `iac/lxc-ssh` | `public_key` | `TF_VAR_ssh_public_key` |
| `iac/cloudflare` | `api_token` | `TF_VAR_cloudflare_api_token` |

The OIDC `sub` claim is bound (vault-config `auth.tf`) to exactly this repo's
**`push` to `main`** and **`pull_request`** events — nothing else can mint a CI
token. TLS to Vault (self-signed homelab CA) is verified against the committed
`environments/homelab/vault-ca.crt` (base64-encoded into vault-action's
`caCertificate`), never `tlsSkipVerify`.

**Cutover complete (PET-29).** CI sources every cred **solely from Vault**. The 4
legacy repo Actions secrets (`MINIO_ACCESS_KEY`, `MINIO_SECRET_KEY`,
`PROXMOX_API_TOKEN`, `LXC_SSH_PUBLIC_KEY`) were **deleted** once a Vault-only apply
proved green on `main` — the lockout guard: never drop the last static fallback
before the Vault path is proven. The Proxmox token was rotated to a scoped privsep
token (runbook below). Never commit creds; `*.tfvars` is gitignored.

### Runbook — rotate the Proxmox API token (PET-55, done)

A **privsep-1** token scoped to `PVEVMAdmin` + `PVEDatastoreUser` on `/` — narrower
than the old `PVEAdmin@/` bootstrap token, but enough for VM/CT lifecycle + disk
allocation:

```bash
# 1. On the PVE node — mint a privsep token (its OWN ACL, not the user's perms).
pveum user token add petedio@pam iac --privsep 1 --output-format json   # capture .value
pveum acl modify / --tokens 'petedio@pam!iac' --roles PVEVMAdmin,PVEDatastoreUser

# 2. Prove it BEFORE Vault: a local `terraform plan` with TF_VAR_proxmox_api_token
#    = the new token must refresh clean. The old token stays the live fallback
#    until this passes.

# 3. Store the full token string in Vault (KV v2). CI reads kv/data/iac/proxmox.
vault kv put kv/iac/proxmox api_token='petedio@pam!iac=<new-secret>'

# 4. Prove in CI (one apply-on-merge green), THEN revoke the old broad token(s):
pveum user token remove petedio@pam petedio        # the bootstrap PVEAdmin token
```
