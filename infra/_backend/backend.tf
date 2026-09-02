# 이 파일은 **template** — terraform backend 블록은 root 안에 있어야 하므로 각 root(cloudflare/github/
# tailscale)가 이 backend 블록의 사본을 둔다. test_backend-drift.bats가 사본↔템플릿 일치를 강제한다(거짓 SSOT 드리프트 차단).
# Cloudflare R2를 가리키는 공유 S3 호환 백엔드.
# root별 state key는 init 시점에 `-backend-config`로 주입한다 — 파생(`<root>/prod/terraform.tfstate`)의
# SSOT는 .github/actions/tf-r2-init이고 증인은 tools/tests/test_tf-r2-init.bats다.
# 시크릿(endpoints, account id, keys)은 오직 backend.hcl(gitignored)에만 둔다.
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
