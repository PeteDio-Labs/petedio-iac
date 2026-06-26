# Secrets in Terraform state — exposure, mitigations, decision (PET-107)

**Status:** decision-gated (see "Recommendation"). This note is the in-repo record;
the tracking issue is **PET-107** (Linear, Platform project).

## The exposure

Every `vault_kv_secret_v2` **data source** in `environments/homelab/` writes its
**entire** secret payload into Terraform state in plaintext — not just the field we
consume, the whole KV entry:

| Data source | File | Plaintext-in-state |
|---|---|---|
| `kv/poker/db` | `postgres.tf` | `DATABASE_URL`, `admin_password`, `poker_password` |
| `kv/admin/db` | `admin.tf` | `owner_password` |
| `kv/iac/cloudflare` | `cloudflare.tf` | `api_token` (+ non-secret `account_id`/`zone_id`/`tunnel_id`) |

On top of the data sources, the **`postgresql_role`** resources
(`modules/postgres-db/main.tf`) persist password material for the `poker` and `admin`
login roles.

That state lives in MinIO reached over **`http://192.168.50.221:9000`** (`backend.tf`),
so the platform's highest-value secrets rest unencrypted and transit the LAN in the
clear, gated only by the MinIO access keys. Anyone who can read the `tfstate` bucket
holds *all* of them — a larger blast radius than any single Vault policy grants
(`vault-config.tfstate` in the same bucket also holds the policy/auth config).

## Why the obvious fix is provider-gated

Terraform 1.10+/1.11+ added the two primitives built for exactly this — **ephemeral
resources** and **write-only (`*_wo`) arguments** — and the runner/local TF here is
**1.15.x**, so the *language* support is present. The gap is **provider** support, and
it is the crux of the decision:

- **Ephemeral `vault_kv_secret_v2`** (reads the secret without ever persisting it to
  state) shipped in the **hashicorp/vault provider `v5.0.0`** (May 2025; requires TF
  ≥ 1.11). This repo pins **`vault = "~> 4.0"`** (`versions.tf`, locked at `4.8.0`),
  which has **no** ephemeral resources. **The data-source leak — the bulk of the blast
  radius — cannot be closed without a `4.x → 5.x` major provider bump.**
- **`postgresql_role.password_wo` / `password_wo_version`** (write the role password
  without persisting it) shipped in **cyrilgdn/postgresql `v1.26.0`** (Sept 2025;
  requires TF ≥ 1.11). The repo pins **`postgresql = "~> 1.0"`**, currently **locked at
  `1.26.0`** — so this one is reachable **without** a constraint change. `password_wo`
  *conflicts with* `password` (mutually exclusive) and pairs with `password_wo_version`,
  which gates *when* the password is re-applied (a version string you bump to rotate).

### Why `password_wo` alone is not a clean win here

`postgresql_role` reads its password from `local.{poker,admin}_db_password`, which is
derived from the **`vault_kv_secret_v2` data source**. Switching the role to
`password_wo` removes the password from the *role resource's* state, but the **same
secret is still in state at the data-source layer** — so on its own it does not shrink
the blast radius, while it *does* add operational surface: `password_wo_version` must be
hand-bumped to propagate a Vault-side rotation (today a rotated Vault value flows through
automatically on the next apply). It only becomes a real, complete fix **together with**
the ephemeral Vault read (v5), where the data source no longer lands in state either.

## Options considered

1. **Vault provider `4 → 5` bump + ephemeral reads + `password_wo`** — the real fix.
   Closes the data-source leak *and* the role-password leak. Cost/risk: a major
   provider upgrade touches the PET-29 OIDC auth path (`provider "vault"` /
   `skip_child_token`), the gated two-phase null handling (`postgres.tf`/`admin.tf`),
   and the Cloudflare token resolution; v5 has its own breaking-change surface. Needs a
   deliberate upgrade pass with a clean plan on `main`, not a drive-by edit.
2. **`password_wo` only** (no provider bump) — partial: leaves the dominant data-source
   leak open and adds `password_wo_version` bookkeeping. Net-negative on its own.
3. **MinIO-over-HTTPS for the state backend** (`backend.tf` → `https`, homelab CA) —
   encrypts state *in transit* and gates it behind TLS, but **secrets still rest
   plaintext in the bucket**. This is the cheapest partial win and is **already tracked
   as PET-112 (sub-item 3 / the LAN-plaintext item)** — *do not duplicate it here*; it
   composes with, but does not substitute for, options 1.
4. **Accept the residual** for the LAN-trust posture (below) and do nothing — the secrets
   are already in Vault by reference, never in code/PRs; state is gated by MinIO keys on a
   LAN that already runs Proxmox/MinIO/Postgres without TLS by deliberate choice
   (`minio-state-backend.tf` / the MinIO ADR, PET-102; `providers.tf` `sslmode=disable`).

## Recommendation

Do option **1** as its own scoped change (a vault-provider-v5 upgrade ticket/PR with a
verified clean plan), because only it actually shrinks the blast radius. Compose it with
**PET-112** (state-backend TLS) for defence-in-depth. Until the v5 bump lands, the
exposure is **accepted residual** under the homelab LAN-trust posture:

- secrets live in Vault and enter Terraform only by reference (never committed, never in
  PRs);
- state access is gated by the MinIO `tfstate` svcacct keys (`kv/iac/minio`,
  bucket-scoped);
- the same LAN-trust ADR that keeps `.221` hand-managed and Postgres `sslmode=disable`
  applies — this is a known, documented trade-off, not an oversight.

**Decision points for review:** (a) approve the vault `4 → 5` bump as a standalone ticket?
(b) adopt `password_wo` *as part of* that bump (recommended) or skip it? (c) confirm
PET-112 owns the state-backend TLS work so this stays de-duplicated.

## References

- Issue: PET-107. Related: PET-112 (LAN plaintext / state-backend TLS), PET-57 (Vault
  Agent template vs. plaintext env on 230), PET-102 (MinIO `.221` hand-managed ADR).
- Affected files: `environments/homelab/{backend,postgres,admin,cloudflare}.tf`,
  `modules/postgres-db/main.tf`.
- Provider support: hashicorp/vault `v5.0.0` (ephemeral `vault_kv_secret_v2`);
  cyrilgdn/postgresql `v1.26.0` (`password_wo`/`password_wo_version`). Both need TF ≥ 1.11
  (runner is 1.15.x).
