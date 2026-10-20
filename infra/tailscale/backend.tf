terraform {
  backend "s3" {
    bucket       = "homelab-tfstate"
    key          = "v2/tailscale/terraform.tfstate"
    region       = "auto"
    use_lockfile = true

    # R2에는 AWS 검증 API가 없고, 자격을 backend 인수에 넣으면 로컬 캐시에 남는다.
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
    use_path_style              = true
  }
}
