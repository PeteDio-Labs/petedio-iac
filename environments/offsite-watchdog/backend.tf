# Own state key in the MinIO `tfstate` bucket, like environments/homelab (see its backend.tf
# for the lockfile and credential notes). Separate state so an AWS fault cannot touch the
# homelab plan, and the other way round.
#
# ⚠ The S3 backend reads AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY for MinIO. The aws provider
# below does NOT: it takes the watchdog IAM user's keys from Vault, so the two never collide.
terraform {
  backend "s3" {
    bucket       = "tfstate"
    key          = "offsite-watchdog/terraform.tfstate"
    endpoints    = { s3 = "http://192.168.50.221:9000" }
    region       = "us-east-1" # MinIO ignores it; Terraform requires it
    use_lockfile = true

    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    use_path_style              = true
  }
}
