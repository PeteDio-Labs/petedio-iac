# required_version bumped 1.7 -> 1.11 for the vault provider v5 upgrade (PET-190):
# v5 requires TF >= 1.11. This config-only workspace writes Vault policy/auth/mounts
# and reads no secrets (no vault_kv_secret_v2), so it gains no ephemeral resources —
# it's bumped purely to keep the provider major in lockstep with environments/homelab
# and stay on a single supported provider line. Applied MANUALLY (see providers.tf);
# NB v5 auth_backend tune blocks now READ tune metadata from Vault, so the bootstrap
# token here needs read on the auth tune paths — a live-plan item, not a code change.
terraform {
  required_version = ">= 1.11"

  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.0"
    }
  }
}
