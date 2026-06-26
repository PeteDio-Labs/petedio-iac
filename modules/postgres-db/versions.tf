# password_wo / password_wo_version (main.tf) need cyrilgdn/postgresql >= 1.26.0 and
# Terraform >= 1.11 (write-only argument support). The root already locks 1.26.0 and
# pins TF >= 1.11; these floors make the module self-documenting if reused (PET-190).
terraform {
  required_version = ">= 1.11"
  required_providers {
    postgresql = {
      source  = "cyrilgdn/postgresql"
      version = ">= 1.26.0"
    }
  }
}
