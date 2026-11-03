# Own state key in the MinIO `tfstate` bucket, like environments/offsite-watchdog (PET-816).
# The S3 backend reads AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY for MinIO. The aws providers
# below take a named profile instead, so the two never collide.
terraform {
  backend "s3" {
    bucket       = "tfstate"
    key          = "portfolio/terraform.tfstate"
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
