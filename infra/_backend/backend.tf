# 이 파일은 **template** — terraform backend 블록은 root 안에 있어야 하므로 각 root(cloudflare/github/
# tailscale)가 이 backend 블록의 사본을 둔다. test_backend-drift.bats가 사본↔템플릿 일치를 강제한다(거짓 SSOT 드리프트 차단).
# Cloudflare R2를 가리키는 공유 S3 호환 백엔드.
# root별 state key는 init 시점에 `-backend-config`로 주입한다.
# 시크릿(endpoints, account id, keys)은 오직 backend.hcl(gitignored)에만 둔다.
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
