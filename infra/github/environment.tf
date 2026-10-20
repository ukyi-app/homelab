# 병합 키 environment(설계 C.4.8, D-04). 배포 브랜치 정책 main(커스텀 정책 하나). secret은 여기 두지 않는다.
# 값은 Infisical homelab-ci-merge가 원본이고 Secret Sync가 HOMELAB_MERGE_KEY 하나를 쓴다(시크릿 리소스는 state에 평문).
#
# 다시 만드는 일은 이 apply로만 하고 그 뒤에 Sync를 다시 실행한다. 지우거나 다시 만들면 secret도 지워진다.
# prevent_destroy는 콘솔 삭제를 막지 못한다. 지워진 뒤 deploy-merge가 돌면 정책 없는 automerge가 자동으로 생기고,
# 그때 Sync를 다시 돌리면 병합 키가 보호 없는 environment에 들어간다. 그래서 Sync 재실행·키 회전·PAT 교체는 모두
# tools/tf-github.sh verify exit 0(guard 9: 정책 [main])을 첫 단계로 한다.
resource "github_repository_environment" "automerge" {
  repository  = local.homelab
  environment = "automerge"
  # 관리자도 배포 브랜치 정책을 우회하지 못하게 한다.
  can_admins_bypass = false

  deployment_branch_policy {
    protected_branches     = false
    custom_branch_policies = true
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "github_repository_environment_deployment_policy" "automerge_main" {
  repository     = local.homelab
  environment    = github_repository_environment.automerge.environment
  branch_pattern = "main"
}
