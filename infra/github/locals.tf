locals {
  homelab = "homelab"
  # 앱 저장소 목록(public만, D-29). 봇 저장소 homelab-bot 포함, 템플릿은 따로 둔다.
  # 새 앱은 이 목록 PR을 병합한 뒤 저장소를 만들고 apply한다(설계 C.7). 목록 밖 public 저장소가 있으면 guard 8이 멈춘다.
  app_repos = toset(jsondecode(file("${path.module}/app-repos.json")))
  # app-main을 거는 저장소: 템플릿 + 앱 저장소. 템플릿 main은 모든 새 앱의 첫 main 내용이다(설계 C.4.7).
  app_main_repos = setunion(["homelab-app-template"], local.app_repos)
  # guard 8의 기대 집합: org의 보관되지 않은 public 저장소 전부.
  public_repos = setunion([local.homelab], local.app_main_repos)

  # 저장소 관리자 역할(RepositoryRole 5). owner의 일상 병합이 이 bypass다(설계 C.4.7 사람 PR의 병합).
  admin_role = 5
  # 필수 검사 ci의 출처 GitHub Actions App(integration ID 15368, 라이브 ruleset ci에서 확인).
  github_actions_app = 15368

  release_tags = ["refs/tags/app-chart-v*", "refs/tags/data-chart-v*", "refs/tags/app-build-v*"]

  # guard 4의 bypass 허용 목록. "<actor_type>:<actor_id>:<bypass_mode>". exempt는 어디에도 두지 않는다.
  homelab_bypass = {
    "main-interim"        = ["RepositoryRole:${local.admin_role}:pull_request"]
    "main-checks"         = []
    "main-review"         = ["Integration:${var.homelab_merge_app_id}:pull_request", "RepositoryRole:${local.admin_role}:pull_request"]
    "deploy-branches"     = ["Integration:${var.homelab_deploy_app_id}:always"]
    "release-tags-lock"   = []
    "release-tags-create" = ["RepositoryRole:${local.admin_role}:always"]
  }
  app_main_bypass = ["RepositoryRole:${local.admin_role}:pull_request"]
}
