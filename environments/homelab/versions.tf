# required_version bumped 1.7 -> 1.11 for the vault provider v5 upgrade (PET-190):
# v5 multiplexes onto the Terraform Plugin Framework and requires TF >= 1.11, the
# floor for ephemeral resources + write-only (`*_wo`) arguments — both used by this
# change to keep secrets out of state. Runner/local TF is 1.15.x, so this is a no-op
# floor raise. postgresql ~> 1.0 already resolves 1.26+, which password_wo needs, so
# no constraint change is required there.
terraform {
  required_version = ">= 1.11"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.66"
    }
    postgresql = {
      source  = "cyrilgdn/postgresql"
      version = "~> 1.0"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5"
    }
  }
}
