# Shared S3-compatible backend pointed at Cloudflare R2.
# Per-root state key is supplied via `-backend-config` at init time.
# Secrets (endpoints, account id, keys) live ONLY in backend.hcl (gitignored).
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
