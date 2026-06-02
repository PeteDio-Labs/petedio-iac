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

Repo Actions secrets: `MINIO_ACCESS_KEY`, `MINIO_SECRET_KEY`, `PROXMOX_API_TOKEN`,
`LXC_SSH_PUBLIC_KEY`. Never commit creds; `*.tfvars` is gitignored.
