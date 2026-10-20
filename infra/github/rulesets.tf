# homelab ruleset 여섯(설계 C.4.7 서버 쪽 장치). 지우지 않고 enforcement를 disabled로만 끈다. 정답은 이 HCL이다.
# 콘솔·gh api로 바꾸면 다음 verify가 차이(exit 2)나 guard 오류(exit 1)로 보인다.

# 임시 ruleset(E1, gh api로 만듦). E5 1단계는 active 그대로 import하고, ruleset B가 main에 걸린 것을 확인한 뒤
# 2단계 PR에서 disabled로 바꾼다. 한 apply로 하면 병렬 적용이나 부분 실패(#3519) 때 main에 필수 검사만 남는다.
# 2단계 뒤에도 선언해 둔다. 빼면 guard 3(이름 집합)이 늘 실패하고, 이름으로 예외를 두면 몰래 바꾼 ruleset을 놓친다.
resource "github_repository_ruleset" "main_interim" {
  repository  = local.homelab
  name        = "main-interim"
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["refs/heads/main"]
      exclude = []
    }
  }

  bypass_actors {
    actor_id    = local.admin_role
    actor_type  = "RepositoryRole"
    bypass_mode = "pull_request"
  }

  rules {
    deletion         = true
    non_fast_forward = true
    pull_request {
      required_approving_review_count   = 1
      require_code_owner_review         = true
      dismiss_stale_reviews_on_push     = true
      require_last_push_approval        = false
      required_review_thread_resolution = false
      allowed_merge_methods             = ["merge", "squash", "rebase"]
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

# A. 필수 검사 ci. bypass 없음. E2의 ruleset ci를 제자리에서 이름만 바꾼다(provider에서 name은 ForceNew가 아니다).
# 검사 이름은 ci.yaml의 job id ci다. job id를 바꾸면 모든 PR이 오지 않는 검사를 기다린다(설계 B.8 E5).
# strict(최신 main 요구)를 끈다. 배포 PR이 서로 다른 파일만 바꿔 BEHIND 정지와 스위퍼가 필요 없다(R17).
resource "github_repository_ruleset" "main_checks" {
  repository  = local.homelab
  name        = "main-checks"
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["refs/heads/main"]
      exclude = []
    }
  }

  rules {
    required_status_checks {
      strict_required_status_checks_policy = false
      do_not_enforce_on_create             = false
      required_check {
        context        = "ci"
        integration_id = local.github_actions_app
      }
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

# B. 사람 검토. owner가 만든 PR은 자기 승인이 안 돼 관리자 bypass(pull_request 모드)로 병합한다.
# 그 bypass는 B에만 있어 A의 ci는 그대로 적용된다(U08). homelab-merge App은 자동 병합 조건을 통과한 PR만 병합한다.
resource "github_repository_ruleset" "main_review" {
  repository  = local.homelab
  name        = "main-review"
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["refs/heads/main"]
      exclude = []
    }
  }

  bypass_actors {
    actor_id    = local.admin_role
    actor_type  = "RepositoryRole"
    bypass_mode = "pull_request"
  }

  bypass_actors {
    actor_id    = var.homelab_merge_app_id
    actor_type  = "Integration"
    bypass_mode = "pull_request"
  }

  rules {
    deletion         = true
    non_fast_forward = true
    pull_request {
      required_approving_review_count   = 1
      require_code_owner_review         = true
      dismiss_stale_reviews_on_push     = true
      require_last_push_approval        = true
      required_review_thread_resolution = false
      allowed_merge_methods             = ["squash"]
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

# C. deploy/** 브랜치는 homelab-deploy App만 만들고 바꾼다(키는 앱 main push의 태그 고정 app-build만 받는다).
# 삭제는 막지 않는다. 병합 뒤 브랜치 삭제 설정이 deploy 브랜치를 지운다.
resource "github_repository_ruleset" "deploy_branches" {
  repository  = local.homelab
  name        = "deploy-branches"
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["refs/heads/deploy/**"]
      exclude = []
    }
  }

  bypass_actors {
    actor_id    = var.homelab_deploy_app_id
    actor_type  = "Integration"
    bypass_mode = "always"
  }

  rules {
    creation = true
    update   = true
  }

  lifecycle {
    prevent_destroy = true
  }
}

# D1. 버전 태그의 갱신·삭제 금지. bypass 없음(관리자 포함). bypass 목록은 ruleset 전체에 걸리므로 생성 제한(D2)과
# 나눈다. 같은 ruleset이면 관리자 bypass가 갱신·삭제까지 우회한다. 잘못 만든 태그는 D1을 잠시 disabled로 바꿔 지운다.
resource "github_repository_ruleset" "release_tags_lock" {
  repository  = local.homelab
  name        = "release-tags-lock"
  target      = "tag"
  enforcement = "active"

  conditions {
    ref_name {
      include = local.release_tags
      exclude = []
    }
  }

  rules {
    update   = true
    deletion = true
  }

  lifecycle {
    prevent_destroy = true
  }
}

# D2. 버전 태그는 관리자만 만든다. 태그 ruleset의 bypass는 always 모드만 된다.
# 배포 키 identity가 app-build-v* 태그 ref에 묶이므로 키를 받는 워크플로 코드도 관리자가 만든 움직이지 않는 태그다.
resource "github_repository_ruleset" "release_tags_create" {
  repository  = local.homelab
  name        = "release-tags-create"
  target      = "tag"
  enforcement = "active"

  conditions {
    ref_name {
      include = local.release_tags
      exclude = []
    }
  }

  bypass_actors {
    actor_id    = local.admin_role
    actor_type  = "RepositoryRole"
    bypass_mode = "always"
  }

  rules {
    creation = true
  }

  lifecycle {
    prevent_destroy = true
  }
}

# 앱 저장소와 템플릿의 main(설계 C.4.7 app-main). App bypass 없음. 자동 배포는 앱 main을 믿으므로 앱 main을 바꿀 수
# 있는 신원이 곧 배포 주체다. 결정 5 하드닝이 같은 모양으로 먼저 건 것을 import한다(imports.tf).
# Free에서는 public 저장소에만 걸린다. private이 되면 자동 병합 조건 9가 멈춘다.
# prevent_destroy를 두지 않는다. app-repos.json에서 빼는 앱 삭제는 delete plan이라 래퍼가 --allow-destroy 없이 멈춘다.
resource "github_repository_ruleset" "app_main" {
  for_each = local.app_main_repos

  repository  = each.key
  name        = "app-main"
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  bypass_actors {
    actor_id    = local.admin_role
    actor_type  = "RepositoryRole"
    bypass_mode = "pull_request"
  }

  rules {
    deletion         = true
    non_fast_forward = true
    pull_request {
      required_approving_review_count   = 1
      require_code_owner_review         = true
      dismiss_stale_reviews_on_push     = true
      require_last_push_approval        = false
      required_review_thread_resolution = false
      allowed_merge_methods             = ["merge", "squash", "rebase"]
    }
  }
}
