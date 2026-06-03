# vault-config — Vault configuration workspace (apply MANUALLY)

A **second, standalone** Terraform workspace that configures the *running*
HashiCorp Vault on LXC 223 (`192.168.50.223:8200`) via the `hashicorp/vault`
provider: the KV v2 mount, least-privilege policies, and the AppRole + GitHub
Actions JWT auth backends.

This is separate from the host that runs Vault — the LXC itself is provisioned by
the main workspace (`environments/homelab/vault.tf` + Ansible). Here we only
configure the service once it's up.

## Why it's a separate workspace

The main workspace (`environments/homelab`) is applied by **public CI** with
`-auto-approve`. Configuring Vault needs the Vault **root / bootstrap token**,
which must **NEVER** enter the public CI loop or the main Terraform state. So this
lives in its own directory with its own state key
(`homelab/vault-config.tfstate`) and is applied **manually** by the operator with
the token in env.

> **This dir must NEVER be added to `terraform.yml`.** The repo CI workflow only
> `cd`s into `environments/homelab`, so this directory is naturally excluded — keep
> it that way.

## How to apply

Set auth via env (out-of-band — never committed). The token comes from the
password manager:

```sh
export VAULT_ADDR=https://192.168.50.223:8200
export VAULT_CACERT=../vault-ca.crt          # self-signed homelab CA bundle
export VAULT_TOKEN=<root/bootstrap token from the password manager>

# MinIO state backend creds (same as the main workspace)
export AWS_ACCESS_KEY_ID=<minio key>
export AWS_SECRET_ACCESS_KEY=<minio secret>

terraform init
terraform plan
terraform apply
```

State is in the fresh MinIO (`.221`, bucket `tfstate`, key
`homelab/vault-config.tfstate`). No locking — single operator, never run
concurrent applies (see `docs/GOTCHAS.md`).

## What it creates

- **`kv`** — KV v2 secrets engine (`kv/data/...` for values, `kv/metadata/...` for
  listing).
- **Policies** (read/list only, least-privilege): `ci-read`, `terraform`,
  `ansible`.
- **AppRole** auth + roles `ansible`, `terraform-local` for local machine logins.
- **JWT** auth (`jwt-github`) + role `github-actions` so GitHub Actions can swap
  its OIDC token for a short-lived `ci-read` token (no static secret in CI).
