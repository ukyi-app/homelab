# Shared S3-compatible backend pointed at Cloudflare R2 (copy of infra/_backend/backend.tf).
# Per-root state key (github/prod/terraform.tfstate) + secrets come from the
# gitignored backend.hcl at init time.
terraform {
  backend "s3" {
    bucket = "homelab-tfstate"
    region = "auto"

    # R2 is not real AWS S3 — disable the AWS-only handshakes.
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
    use_path_style              = true
  }
}
