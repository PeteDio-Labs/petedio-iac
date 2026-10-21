# aws ~> 6 for aws_ssm_parameter `value_wo`: the Discord webhook and the heartbeat secret
# reach SSM from an ephemeral Vault read and never land in Terraform state (PET-107).
terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.0"
    }
  }
}
