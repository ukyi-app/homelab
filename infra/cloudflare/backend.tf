# Cloudflare R2를 가리키는 공유 S3 호환 백엔드 (infra/_backend/backend.tf의 사본;
# Terraform은 backend 블록이 root 안에 있어야 한다). root별 state key와 시크릿은
# init 시점에 gitignored된 backend.hcl에서 들어온다.
# state key 파생(`<root>/prod/terraform.tfstate`)의 SSOT는 .github/actions/tf-r2-init다 —
# 여기 리터럴을 적지 않는다(같은 등식의 사본이 늘면 그게 곧 드리프트 면이다).
# ⚠️ **state 잠금이 없다.** 1.9.x S3 backend는 `dynamodb_table` 없이 잠그지 않고 `use_lockfile`은 1.10+다 —
#    그래서 워크플로의 `-lock-timeout=120s`는 no-op이다(잠금 도입 시 살아나는 선행 핀이라 유지한다).
#    직렬화는 CI `homelab-mutation` concurrency 그룹뿐이고, 그 그룹은 owner 로컬 apply를 덮지 못한다:
#    cloudflare 루트를 로컬에서 apply하기 전(guard=blocked-delete 경로)에는
#    `gh run list -w tf-reconcile.yaml --status in_progress`가 비어 있는지 확인할 것.
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
