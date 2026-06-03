terraform {
  required_version = ">= 1.7.0"

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
      version = "~> 4.0"
    }
  }
}
