# Actions 허용 범위(설계 C.4.10). selected: GitHub 소유, 검증된 제작자, Infisical/secrets-action.
# 워크플로가 실제로 쓰는 목록은 ci의 workflow-guard(tools/ci/workflow-guard.ts)가 더 좁게 본다. 늘릴 때는 둘을 함께 바꾼다.
resource "github_actions_repository_permissions" "homelab" {
  repository      = local.homelab
  enabled         = true
  allowed_actions = "selected"

  allowed_actions_config {
    github_owned_allowed = true
    verified_allowed     = true
    patterns_allowed     = ["Infisical/secrets-action@*"]
  }
}

# 기본 GITHUB_TOKEN은 읽기, PR 승인 불가. 워크플로는 job마다 permissions를 최소로 선언한다.
resource "github_workflow_repository_permissions" "homelab" {
  repository                       = local.homelab
  default_workflow_permissions     = "read"
  can_approve_pull_request_reviews = false
}
