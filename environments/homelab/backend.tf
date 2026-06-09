# State lives in the FRESH MinIO (LXC 221 / .221, bucket `tfstate`, versioning on).
# This is the greenfield state backend — distinct from the old MinIO at .115.
#
# Locking: S3-NATIVE lockfile (use_lockfile, TF >= 1.10) — a conditional
# If-None-Match PUT of a .tflock object next to the state key; modern MinIO
# supports conditional writes, no DynamoDB needed. PET-105: this plus the
# tf-homelab CI concurrency group replaces the old convention-only "never run
# concurrent applies" rule. Bucket versioning remains the recovery net.
# NB: adding use_lockfile changes the backend config — existing local workdirs
# need a one-time `terraform init -reconfigure` (CI checkouts are always fresh).
#
# Credentials come from env vars AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
# (locally) or the runner's Actions secrets. Never put them inline here.

terraform {
  backend "s3" {
    bucket       = "tfstate"
    key          = "homelab/terraform.tfstate"
    endpoints    = { s3 = "http://192.168.50.221:9000" }
    region       = "us-east-1" # MinIO ignores it; Terraform requires it
    use_lockfile = true        # S3-native state lock (PET-105)

    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    use_path_style              = true
  }
}
