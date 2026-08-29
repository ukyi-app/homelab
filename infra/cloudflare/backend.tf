# Cloudflare R2를 가리키는 공유 S3 호환 백엔드 (infra/_backend/backend.tf의 사본;
# Terraform은 backend 블록이 root 안에 있어야 한다). root별 state key와 시크릿은
# init 시점에 gitignored된 backend.hcl에서 들어온다.
# state key 파생(`<root>/prod/terraform.tfstate`)의 SSOT는 .github/actions/tf-r2-init다 —
# 여기 리터럴을 적지 않는다(같은 등식의 사본이 늘면 그게 곧 드리프트 면이다).
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
