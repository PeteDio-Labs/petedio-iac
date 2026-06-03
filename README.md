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

The OIDC `sub` claim is bound (vault-config `auth.tf`) to exactly this repo's
**`push` to `main`** and **`pull_request`** events — nothing else can mint a CI
token. TLS to Vault (self-signed homelab CA) is verified against the committed
`environments/homelab/vault-ca.crt` (base64-encoded into vault-action's
`caCertificate`), never `tlsSkipVerify`.

**Two-phase cutover.** *Phase 1 (now):* the 4 legacy repo Actions secrets
(`MINIO_ACCESS_KEY`, `MINIO_SECRET_KEY`, `PROXMOX_API_TOKEN`, `LXC_SSH_PUBLIC_KEY`)
**remain** as a job-level `env` overlap/fallback; vault-action overrides them at
runtime via `$GITHUB_ENV`. Prove one green Vault-sourced apply on merge. *Phase 2
(separate PR):* delete the 4 static secrets + rotate the Proxmox token (runbook
below). Never commit creds; `*.tfvars` is gitignored.

> CI stays **RED** until the Vault KV values above are seeded (PET-27) —
> vault-action cannot read secrets that do not exist yet.

### Runbook — rotate the Proxmox API token (Phase 2)

Executed by the operator once the Vault-OIDC path is proven. Mints a NEW token
scoped **narrower than `PVEAdmin@/`**, stores it in Vault, applies once, then
revokes the old token:

```bash
# 1. On the PVE node — mint a fresh, narrowly-scoped token for petedio@pam.
#    Scope to only what the IaC needs (VM/CT lifecycle on the target node),
#    NOT a blanket PVEAdmin on '/'. Capture the printed secret.
pveum user token add petedio@pam petedio --privsep 0
#    (and ensure an ACL narrower than PVEAdmin@/ grants exactly the needed perms)

# 2. Store the full token string in Vault (KV v2). CI reads kv/data/iac/proxmox.
vault kv put kv/iac/proxmox api_token='petedio@pam!petedio=<new-secret>'

# 3. Trigger ONE terraform apply (merge a no-op/PR) so CI proves the new token.

# 4. Revoke the OLD token on the node — only after the apply above is green.
pveum user token remove petedio@pam <old-token-id>
```
