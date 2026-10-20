# guard 아홉(설계 C.3.9). check 블록이 아니라 github_rest_api 데이터 소스의 postcondition이다.
# check는 실패해도 경고만 내고 plan이 초록으로 끝난다. postcondition은 plan을 오류로 멈춘다.
# github_rest_api는 provider 인증을 다시 써서 토큰이 state에 남지 않는다. 404는 오류가 아니라 code 404다.
#
# 관리 자원의 내용을 보는 guard 3·4·9에만 그 자원에 대한 의존을 건다. 변경이 예정되면 읽기가 apply 뒤로 미뤄져
# 고친 뒤 상태를 본다. 나머지(1·2·5·6·7·8)는 의존이 없어 plan 때 늘 평가된다. 그래서 admin이 아닌 토큰은
# ruleset 변경 예정과 상관없이 guard 1에서 멈춘다. 미뤄진 guard 결과는 plan 출력에 없으므로 apply 뒤 verify를 다시 돈다.
#
# 조건은 try(..., false)로 감싼다. 응답 모양이 달라 식이 깨져도 평가 오류가 아니라 guard 실패로 보이게 하려는 것이다.

# 1. 토큰이 homelab admin. 익명 폴백과 권한 부족을 드리프트가 아니라 오류로 바꾼다.
#    쓰기 권한이 없는 토큰에는 bypass 목록과 병합 설정이 안 보여 허위 드리프트가 난다.
data "github_rest_api" "token_admin" {
  endpoint = "repos/ukyi-app/homelab"

  lifecycle {
    postcondition {
      condition     = try(self.code == 200 && jsondecode(self.body).permissions.admin == true, false)
      error_message = "guard 1: GITHUB_TOKEN이 ukyi-app/homelab의 admin이 아니다(익명 폴백·권한 부족). 토큰을 확인한다."
    }
  }
}

# 2. 저장소 설정. 리소스가 아니라 gh api로 맞추고 여기서 확인만 한다(github_repository를 두지 않아 destroy로 지울 길이 없다).
data "github_rest_api" "repo_homelab" {
  endpoint = "repos/ukyi-app/homelab"

  lifecycle {
    postcondition {
      condition = try(
        jsondecode(self.body).visibility == "public" &&
        jsondecode(self.body).allow_auto_merge == false &&
        jsondecode(self.body).allow_squash_merge == true &&
        jsondecode(self.body).allow_merge_commit == false &&
        jsondecode(self.body).allow_rebase_merge == false &&
        jsondecode(self.body).delete_branch_on_merge == true,
        false
      )
      error_message = "guard 2: homelab 설정이 public, allow_auto_merge=false, squash만, 병합 뒤 브랜치 삭제가 아니다. gh api -X PATCH로 맞춘다."
    }
  }
}

data "github_rest_api" "repo_app" {
  for_each = local.app_main_repos
  endpoint = "repos/ukyi-app/${each.key}"

  lifecycle {
    postcondition {
      condition = try(
        jsondecode(self.body).visibility == "public" &&
        jsondecode(self.body).security_and_analysis.secret_scanning.status == "enabled" &&
        jsondecode(self.body).security_and_analysis.secret_scanning_push_protection.status == "enabled",
        false
      )
      error_message = "guard 2: 앱 저장소·템플릿이 public이 아니거나 secret scanning·push protection이 꺼져 있다(D-29)."
    }
  }
}

data "github_rest_api" "private_vulnerability_reporting" {
  for_each = local.app_main_repos
  endpoint = "repos/ukyi-app/${each.key}/private-vulnerability-reporting"

  lifecycle {
    postcondition {
      condition     = try(self.code == 200 && jsondecode(self.body).enabled == true, false)
      error_message = "guard 2: private vulnerability reporting이 꺼져 있다(D-29). gh api -X PUT repos/ukyi-app/<저장소>/private-vulnerability-reporting."
    }
  }
}

# 3. 저장소별 ruleset 이름 집합과 개수(같은 이름 중복도 잡는다). 선언 밖 ruleset이 생기면 멈춘다.
data "github_rest_api" "rulesets_homelab" {
  endpoint = "repos/ukyi-app/homelab/rulesets?includes_parents=false&per_page=100"
  depends_on = [
    github_repository_ruleset.main_interim,
    github_repository_ruleset.main_checks,
    github_repository_ruleset.main_review,
    github_repository_ruleset.deploy_branches,
    github_repository_ruleset.release_tags_lock,
    github_repository_ruleset.release_tags_create,
  ]

  lifecycle {
    postcondition {
      condition     = try(jsonencode(sort([for r in jsondecode(self.body) : r.name])) == jsonencode(sort(keys(local.homelab_bypass))), false)
      error_message = "guard 3: homelab의 ruleset 이름 집합·개수가 선언과 다르다(선언 밖 ruleset 또는 중복)."
    }
  }
}

data "github_rest_api" "rulesets_app" {
  for_each   = local.app_main_repos
  endpoint   = "repos/ukyi-app/${each.key}/rulesets?includes_parents=false&per_page=100"
  depends_on = [github_repository_ruleset.app_main]

  lifecycle {
    postcondition {
      condition     = try(jsonencode([for r in jsondecode(self.body) : r.name]) == jsonencode(["app-main"]), false)
      error_message = "guard 3: 앱 저장소·템플릿의 ruleset이 app-main 하나가 아니다."
    }
  }
}

# 4. ruleset별 bypass가 허용 목록과 같은지, exempt 금지. 응답에 bypass_actors가 없으면 실패(쓰기 권한 없는 토큰).
#    provider state를 거치지 않는 GET이라 #3519로 state가 낡아도 bypass는 잡는다.
locals {
  homelab_rulesets = {
    "main-interim"        = github_repository_ruleset.main_interim
    "main-checks"         = github_repository_ruleset.main_checks
    "main-review"         = github_repository_ruleset.main_review
    "deploy-branches"     = github_repository_ruleset.deploy_branches
    "release-tags-lock"   = github_repository_ruleset.release_tags_lock
    "release-tags-create" = github_repository_ruleset.release_tags_create
  }
}

data "github_rest_api" "bypass_homelab" {
  for_each = local.homelab_rulesets
  endpoint = "repos/ukyi-app/homelab/rulesets/${each.value.ruleset_id}"

  lifecycle {
    postcondition {
      condition = try(
        jsonencode(sort([for a in jsondecode(self.body).bypass_actors : "${a.actor_type}:${a.actor_id == null ? "null" : a.actor_id}:${a.bypass_mode}"])) == jsonencode(sort(local.homelab_bypass[each.key])) &&
        alltrue([for a in jsondecode(self.body).bypass_actors : a.bypass_mode != "exempt"]),
        false
      )
      error_message = "guard 4: homelab ruleset의 bypass가 허용 목록과 다르거나 exempt가 있다(또는 bypass_actors가 응답에 없다)."
    }
  }
}

data "github_rest_api" "bypass_app" {
  for_each = local.app_main_repos
  endpoint = "repos/ukyi-app/${each.key}/rulesets/${github_repository_ruleset.app_main[each.key].ruleset_id}"

  lifecycle {
    postcondition {
      condition = try(
        jsonencode(sort([for a in jsondecode(self.body).bypass_actors : "${a.actor_type}:${a.actor_id == null ? "null" : a.actor_id}:${a.bypass_mode}"])) == jsonencode(sort(local.app_main_bypass)),
        false
      )
      error_message = "guard 4: app-main의 bypass가 저장소 관리자(pull_request)만이 아니다. App bypass는 두지 않는다(D-26 조건 (1))."
    }
  }
}

# 5. main에 유효한 CODEOWNERS. 404는 파일 없음이고, 깨진 줄은 건너뛰어 code owner가 지정되지 않는다(조건 9).
data "github_rest_api" "codeowners" {
  for_each = local.public_repos
  endpoint = "repos/ukyi-app/${each.key}/codeowners/errors?ref=main"

  lifecycle {
    postcondition {
      condition     = try(self.code == 200 && length(jsondecode(self.body).errors) == 0, false)
      error_message = "guard 5: main의 CODEOWNERS가 없거나(404) 오류가 있다. code owner 리뷰 요구가 효력을 잃는다."
    }
  }
}

# 6. 옛 브랜치 보호가 없다(E1에서 지움). ruleset과 둘이 겹치면 어느 쪽이 막는지 흐려진다.
data "github_rest_api" "branch_protection" {
  for_each = local.public_repos
  endpoint = "repos/ukyi-app/${each.key}/branches/main/protection"

  lifecycle {
    postcondition {
      condition     = self.code == 404
      error_message = "guard 6: main에 옛 브랜치 보호가 있다. ruleset만 쓴다."
    }
  }
}

# 7. fork PR 승인 정책이 org와 public 저장소마다 all_external_contributors(D-29). provider가 지원하지 않아 gh api PUT.
data "github_rest_api" "fork_approval_org" {
  endpoint = "orgs/ukyi-app/actions/permissions/fork-pr-contributor-approval"

  lifecycle {
    postcondition {
      condition     = try(jsondecode(self.body).approval_policy == "all_external_contributors", false)
      error_message = "guard 7: org의 fork PR 승인 정책이 all_external_contributors가 아니다."
    }
  }
}

data "github_rest_api" "fork_approval" {
  for_each = local.public_repos
  endpoint = "repos/ukyi-app/${each.key}/actions/permissions/fork-pr-contributor-approval"

  lifecycle {
    postcondition {
      condition     = try(jsondecode(self.body).approval_policy == "all_external_contributors", false)
      error_message = "guard 7: 저장소의 fork PR 승인 정책이 all_external_contributors가 아니다."
    }
  }
}

# 8. org의 보관되지 않은 public 저장소 = homelab + 템플릿 + app-repos.json. 목록 밖 public 저장소는 app-main도
#    조건 9도 없는 앱 경로가 된다.
data "github_rest_api" "public_repos" {
  endpoint = "orgs/ukyi-app/repos?type=public&per_page=100"

  lifecycle {
    postcondition {
      condition     = try(jsonencode(sort([for r in jsondecode(self.body) : r.name if !r.archived])) == jsonencode(sort(local.public_repos)), false)
      error_message = "guard 8: org의 public 저장소 집합이 homelab + homelab-app-template + app-repos.json과 다르다."
    }
  }
}

# 9. environment automerge의 배포 브랜치 정책 [main], secret 이름 집합 [] 또는 [HOMELAB_MERGE_KEY],
#    repo secret 0개, org secret 0개(D-04). 키가 없는 상태([])는 받아들인다. environment를 다시 만든 직후와
#    1단계 apply 직후는 Sync 전이라 비어 있고, 여기서 막으면 Sync 재실행 앞의 verify가 스스로 막힌다.
#    키가 있는지는 E5 완료 기준과 회전 절차의 updated_at 확인이 따로 본다.
data "github_rest_api" "automerge_policies" {
  endpoint   = "repos/ukyi-app/homelab/environments/automerge/deployment-branch-policies?per_page=100"
  depends_on = [github_repository_environment.automerge, github_repository_environment_deployment_policy.automerge_main]

  lifecycle {
    postcondition {
      condition     = try(jsonencode([for p in jsondecode(self.body).branch_policies : "${try(p.type, "branch")}:${p.name}"]) == jsonencode(["branch:main"]), false)
      error_message = "guard 9: environment automerge의 배포 브랜치 정책이 [main] 하나가 아니다. Sync를 돌리기 전에 apply로 맞춘다."
    }
  }
}

data "github_rest_api" "automerge_secrets" {
  endpoint   = "repos/ukyi-app/homelab/environments/automerge/secrets?per_page=100"
  depends_on = [github_repository_environment.automerge]

  lifecycle {
    postcondition {
      condition     = try(contains(["[]", "[\"HOMELAB_MERGE_KEY\"]"], jsonencode(sort([for s in jsondecode(self.body).secrets : s.name]))), false)
      error_message = "guard 9: environment automerge의 secret이 [] 또는 [HOMELAB_MERGE_KEY]가 아니다."
    }
  }
}

data "github_rest_api" "repo_secrets" {
  endpoint = "repos/ukyi-app/homelab/actions/secrets?per_page=100"

  lifecycle {
    postcondition {
      condition     = try(jsondecode(self.body).total_count == 0, false)
      error_message = "guard 9: homelab에 repo secret이 있다. 병합 키는 environment automerge에만 둔다(Sync 범위 확인)."
    }
  }
}

data "github_rest_api" "org_secrets" {
  endpoint = "orgs/ukyi-app/actions/secrets?per_page=100"

  lifecycle {
    postcondition {
      condition     = try(jsondecode(self.body).total_count == 0, false)
      error_message = "guard 9: org secret이 있다. 어느 브랜치 워크플로든 읽을 수 있다."
    }
  }
}
