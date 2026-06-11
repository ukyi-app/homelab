# Cloudflare R2를 가리키는 공유 S3 호환 백엔드 (infra/_backend/backend.tf의 사본).
# root별 state key(github/prod/terraform.tfstate)와 시크릿은
# init 시점에 gitignored된 backend.hcl에서 들어온다.
terraform {
  backend "s3" {
    bucket = "homelab-tfstate"
    region = "auto"

    # R2는 진짜 AWS S3가 아니다 — AWS 전용 핸드셰이크를 비활성화한다.
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
    use_path_style              = true
  }
}
