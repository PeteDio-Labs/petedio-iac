# State lives in the FRESH MinIO (LXC 221 / .221, bucket `tfstate`, versioning on).
# This is the greenfield state backend — distinct from the old MinIO at .115.
#
# DISTINCT KEY: this workspace owns the Vault *configuration* (mounts, policies,
# auth backends) and is applied MANUALLY by the operator with the Vault root token
# in env — so it keeps its own state key, separate from the main homelab state.
#
# Locking: S3-NATIVE lockfile (use_lockfile, TF >= 1.10) — same as the main
# homelab backend (PET-105). apply-vault-config.sh inits with -reconfigure, so
# the backend-config change is picked up automatically on the next operator run.
# Bucket versioning remains the recovery net.
#
# Credentials come from env vars AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
# (locally). Never put them inline here.

terraform {
  backend "s3" {
    bucket       = "tfstate"
    key          = "homelab/vault-config.tfstate"
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
