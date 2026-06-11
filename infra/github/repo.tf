resource "github_repository" "homelab" {
  name = var.repo_name
  # public: 무료 플랜은 private repo에 branch protection을 지원하지 않는다(ruleset도 동일).
  # 시크릿은 전부 SOPS 암호화(.enc.yaml)로만 커밋되는 설계(+pre-commit gitleaks)이고,
  # public 전환으로 아래 서버측 secret scanning + push protection이 무료로 켜져 방어가 두터워진다.
  visibility = "public"
  security_and_analysis {
    secret_scanning {
      status = "enabled"
    }
    secret_scanning_push_protection {
      status = "enabled"
    }
  }
  has_issues             = true
  allow_merge_commit     = false
  allow_squash_merge     = true
  allow_rebase_merge     = false
  delete_branch_on_merge = true
  # repo는 이미 존재한다 — 최초 1회 import 필요: 런북 02 참고.
}

# 외부 앱 레포의 출발점 — "Use this template"용. 내용(caller 워크플로/.homelab.yaml/Dockerfile)은
# 최초 1회 push로 시드한다(런북 app-onboarding 참고).
resource "github_repository" "app_template" {
  name        = "homelab-app-template"
  description = "homelab 앱 템플릿: .homelab.yaml 채우고 push하면 온보딩 PR이 자동 생성된다"
  visibility  = "public"
  is_template = true
  auto_init   = true # main 브랜치 생성(내용 push 대상)
  has_issues  = false
}

resource "github_branch_protection" "main" {
  repository_id = github_repository.homelab.node_id
  pattern       = "main"

  required_status_checks {
    strict   = true
    contexts = ["gate"] # pull_request에서는 `gate`만 실행된다(ci.yaml); `build`는 push-to-main(머지 후)에서 돌므로 필수 PR 체크로 넣으면 안 된다 — 넣으면 모든 PR이 영원히 pending에 걸린다
  }
  required_pull_request_reviews {
    required_approving_review_count = 0
    require_last_push_approval      = false
  }
  enforce_admins      = false
  allows_force_pushes = false
  allows_deletions    = false
}
