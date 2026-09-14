# 서버 경계: branch main 한 개만 허용한다. tag main·PR merge refs·aiops/*는 허용하지 않는다.
# Environment 생성만으로 repository/organization 시크릿 공급은 사라지지 않는다.
# 전환 순서·원본 공급 회수는 README.md의 owner-local 절차를 따른다.
resource "github_repository_environment" "main" {
  repository        = data.github_repository.homelab.name
  environment       = "homelab-main"
  can_admins_bypass = false

  deployment_branch_policy {
    protected_branches     = false
    custom_branch_policies = true
  }
}

resource "github_repository_environment_deployment_policy" "main" {
  repository     = data.github_repository.homelab.name
  environment    = github_repository_environment.main.environment
  branch_pattern = "main"
}
