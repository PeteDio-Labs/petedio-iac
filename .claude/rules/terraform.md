---
paths:
  - "environments/**"
  - "modules/**"
---

# Terraform and Proxmox rules

Each rule is the short form. The narrative is in the cited `docs/GOTCHAS.md` section.

- Keep `features`, `mount_point`, `idmap`, `console`, `startup`, `template_file_id` and `user_account` in `ignore_changes`. bpg can't round-trip them, and an API token can't set features or bind mounts (docs/GOTCHAS.md: "Proxmox / bpg").
- A brownfield import must match live config exactly: NIC name, `hwaddr`, NIC firewall, DNS, `os_type`. Read it first with `scripts/proxmox-ro-config.sh` (docs/GOTCHAS.md: "Proxmox / bpg").
- `pct set --features` replaces the whole string, and `pct config` shows declared, not running, features. Converge them with `playbooks/configure-lxc-features.yml` (docs/GOTCHAS.md: "Proxmox / bpg").
- The LAN bridge is `vmbr0` on pve02 and pve03. A config recovered from pve01 says `vmbr1`, so reset the bridge and keep `hwaddr` on migrate (docs/GOTCHAS.md: "Cluster + storage — pve02 + pve03 + QDevice (post 2026-09-03)").
- Storage is per node: scope it with `nodes`, and pve03 has no `local-lvm`. Run `pct listsnapshot` before stopping a guest to migrate (docs/GOTCHAS.md: "Cluster + storage — pve02 + pve03 + QDevice (post 2026-09-03)").
- The MinIO backend needs `use_path_style` and all four `skip_*` flags. Locking is `use_lockfile`, and bucket versioning is the recovery net (docs/GOTCHAS.md: "MinIO S3 state backend").
- Before any local plan, export `TF_VAR_manage_resource_pool` and `TF_VAR_postgres_db_password_versions` from `gh variable list`. Any destroy in an additive change is a stop (docs/GOTCHAS.md: "Terraform — a local plan/apply is NOT the same plan CI runs").
- A new database's secret needs a `ci-read` grant in `vault-config`. That root is operator-applied, so apply it before the merge (docs/GOTCHAS.md: "Terraform — a local plan/apply is NOT the same plan CI runs").
- Verify Vault TLS against `vault-ca.crt`, never skip it. `bound_claims` takes one comma-separated string. The `petedio-iac` role binds the main-push `sub` only (docs/GOTCHAS.md: "Vault — TLS + GitHub-OIDC (PET-29)").
- `terraform validate` needs `VAULT_ADDR` set, even offline (docs/GOTCHAS.md: "Vault — TLS + GitHub-OIDC (PET-29)").
- Read secrets with `ephemeral`, which can flow only into provider config, `*_wo` args or ephemeral outputs. Bump `password_wo_version` to rotate (docs/GOTCHAS.md: "Vault provider v5 — ephemeral reads + write-only (PET-190 / PET-107)").
- After `terraform init -upgrade`, re-run `terraform providers lock` for `linux_amd64` and both darwin platforms (docs/GOTCHAS.md: "Vault provider v5 — ephemeral reads + write-only (PET-190 / PET-107)").
- In Cloudflare v5, Access `policies` is a list of `{ id = … }` objects, and validate won't catch a bare id. A DNS record `depends_on` its Access app (docs/GOTCHAS.md: "Cloudflare — tunnel ingress + Access (PET-35/187/38)").
- Express a repair as an `import`, `removed` or `moved` block, or `ignore_changes`, before writing a script. `removed` cannot address one `for_each` instance (docs/GOTCHAS.md: "Declare it, don't run it: Terraform blocks before scripts").
