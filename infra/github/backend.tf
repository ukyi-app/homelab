terraform {
  backend "s3" {
    bucket = "homelab-tfstate"
    # 옛 키(<root>/prod/...)를 쓰지 않는다. 같은 키면 옛 state를 물려받아 plan이 옛 자원 삭제를 제안한다.
    key          = "v2/github/terraform.tfstate"
    region       = "auto"
    use_lockfile = true

    # R2에는 AWS 검증 API가 없고, 자격을 backend 인수에 넣으면 로컬 캐시에 남는다.
    # endpoint는 tools/tf-github.sh가 -backend-config로 넣고 자격은 환경변수로만 받는다.
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
    use_path_style              = true
  }
}
