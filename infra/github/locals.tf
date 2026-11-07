locals {
  homelab = "homelab"
  # 앱 저장소 목록(public만, D-29). 봇 저장소 homelab-bot 포함, 템플릿은 따로 둔다.
  # 새 앱은 이 목록 PR을 병합한 뒤 저장소를 만들고 apply한다(설계 C.7). 목록 밖 public 저장소가 있으면 guard 8이 멈춘다.
  app_repos = toset(jsondecode(file("${path.module}/app-repos.json")))
  # app-main을 거는 저장소: 템플릿 + 앱 저장소. 템플릿 main은 모든 새 앱의 첫 main 내용이다(설계 C.4.7).
  app_main_repos = setunion(["homelab-app-template"], local.app_repos)
  # guard 8의 기대 집합: org의 보관되지 않은 public 저장소 전부.
  public_repos = setunion([local.homelab], local.app_main_repos)
  # ruleset E를 두는 저장소(D-24). E와 guard 3·4의 기대가 모두 여기서 나온다. ukyi-writer 설치는 이 집합의 부분집합이어야 한다.
  # 설치 자체는 GitHub 설정이고 Terraform은 실제 설치 목록을 대조하지 못한다. 설치 밖 저장소의 E는 다른 신원의 bot/ 쓰기만 막는다.
  # homelab을 app-repos.json에 넣어 맞추면 app-main·guard 2·조건 9의 앱 저장소 규칙이 homelab에 걸리니 넣지 않는다.
  # 설치와 기능 개방은 다르다. homelab에서 무엇을 바꾸게 할지는 게시 서버 정책(change.repositories)이 따로 좁힌다.
  # homelab은 지금 설치돼 있지 않다(T19 AC-P8 뒤 뺌, 사용자 결정 2026-11-07). E를 지우는 것은 ruleset 삭제라 남겨 두었다.
  # 다시 설치하면 E·guard가 이미 맞아 있다. 설치는 별도 승인(D-24)이다.
  writer_repos = toset([local.homelab, "homelab-smoke"])
  # E를 둘 수 있는 저장소(rulesets.tf E의 precondition). 템플릿은 일부러 뺀다. 템플릿 main은 모든 새 앱의 첫 main 내용이라
  # writer를 설치하지 않으며(D-24), 여기 넣으면 오타와 함께 막던 설치 범위가 넓어진다.
  writer_allowed_repos = setunion([local.homelab], local.app_repos)

  # 저장소 관리자 역할(RepositoryRole 5). owner의 일상 병합이 이 bypass다(설계 C.4.7 사람 PR의 병합).
  admin_role = 5
  # 필수 검사 ci의 출처 GitHub Actions App(integration ID 15368, 라이브 ruleset ci에서 확인).
  github_actions_app = 15368

  release_tags = ["refs/tags/app-chart-v*", "refs/tags/data-chart-v*", "refs/tags/app-build-v*"]

  # guard 4의 bypass 허용 목록. "<actor_type>:<actor_id>:<bypass_mode>". exempt는 어디에도 두지 않는다.
  # homelab의 E는 여기 없다. E의 bypass는 bypass_bot_branches가 bot_branches_bypass로 본다. writer App을 이 표에 넣으면
  # guard 4가 main·deploy에 복사된 bypass를 통과시킨다.
  homelab_bypass = {
    "main-interim"        = ["RepositoryRole:${local.admin_role}:pull_request"]
    "main-checks"         = []
    "main-review"         = ["Integration:${var.homelab_merge_app_id}:pull_request", "RepositoryRole:${local.admin_role}:pull_request"]
    "deploy-branches"     = ["Integration:${var.homelab_deploy_app_id}:always"]
    "release-tags-lock"   = []
    "release-tags-create" = ["RepositoryRole:${local.admin_role}:always"]
  }
  app_main_bypass     = ["RepositoryRole:${local.admin_role}:pull_request"]
  bot_branches_bypass = ["Integration:${var.homelab_writer_app_id}:always"]
}
