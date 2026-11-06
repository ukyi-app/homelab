# guard 음성 시험(설계 C.3.9 CI 시험). 자격 없이 mock provider로 HCL 식만 검증한다. 실제 API 응답 모양의 변화는 보지 못한다.
#
# 모든 guard 인스턴스에 정상 JSON을 파일 단위 override_data로 넣고, run마다 하나만 망가뜨린다.
#
# command는 guard 종류로 고른다(Terraform 1.16 test 실측. 설계 C.3.9의 apply 하나로는 안 된다).
# - 의존이 있어 미뤄지는 guard 3·4·9의 관리 자원 쪽은 apply다. plan이면 평가되지 않아 expect_failures가 성립하지 않는다.
#   run마다 state_key를 달리해 빈 state에서 자원을 만들게 한다. 앞 run이 만든 state를 이어 쓰면 변경이 없어 guard가
#   plan 때 평가되고, apply run의 plan 단계 기대 실패를 Terraform test는 "Expected failure while planning"으로 실패 처리한다.
#   state_key 없는 plan run(g3_app_extra, g4_checks_bypass, g4_app_main_app_bypass 등)은 첫 run all_guards_pass(apply)가
#   기본 state에 만든 자원을 이어 써 변경이 없으므로 guard가 plan 때 평가된다. 그래서 all_guards_pass는 맨 앞에 둔다.
# - 의존이 없어 plan 때 늘 평가되는 guard(1·2·5·6·7·8, repo·org secret)는 plan이다. 같은 이유로 apply로는 시험할 수 없다.
# 덮어쓰지 않은 계산 문자열은 mock이 임의 8자를 넣어 나머지 guard까지 실패한다.
#
# guard 8의 org public 저장소 응답은 app-repos.json에서 만든다. app new의 목록 PR은 app-repos.json만 고치므로,
# 이름을 손으로 적어 두면 그 PR의 ci가 여기서 깨진다. ci는 mock이라 실제 org를 읽지 않는다.
# file() 경로는 terraform test를 도는 root(infra/github) 기준이다. 시험 파일의 variables는 override_data에서 못 쓴다.

variables {
  homelab_deploy_app_id = 1000001
  homelab_merge_app_id  = 1000002
  homelab_writer_app_id = 1000003
}

mock_provider "github" {}

override_data {
  target = data.github_rest_api.token_admin
  values = { code = 200, body = "{\"permissions\":{\"admin\":true}}" }
}

override_data {
  target = data.github_rest_api.repo_homelab
  values = { code = 200, body = "{\"visibility\":\"public\",\"default_branch\":\"main\",\"allow_auto_merge\":false,\"allow_squash_merge\":true,\"allow_merge_commit\":false,\"allow_rebase_merge\":false,\"delete_branch_on_merge\":true,\"pull_request_creation_policy\":\"collaborators_only\"}" }
}

override_data {
  target = data.github_rest_api.repo_app
  values = { code = 200, body = "{\"visibility\":\"public\",\"default_branch\":\"main\",\"security_and_analysis\":{\"secret_scanning\":{\"status\":\"enabled\"},\"secret_scanning_push_protection\":{\"status\":\"enabled\"}},\"pull_request_creation_policy\":\"collaborators_only\"}" }
}

override_data {
  target = data.github_rest_api.private_vulnerability_reporting
  values = { code = 200, body = "{\"enabled\":true}" }
}

override_data {
  target = data.github_rest_api.interaction_limit_org
  values = { code = 200, body = "{\"limit\":\"collaborators_only\",\"origin\":\"organization\",\"expires_at\":\"2999-01-01T00:00:00Z\"}" }
}

override_data {
  target = data.github_rest_api.rulesets_homelab
  values = { code = 200, body = "[{\"name\":\"main-interim\"},{\"name\":\"main-checks\"},{\"name\":\"main-review\"},{\"name\":\"deploy-branches\"},{\"name\":\"release-tags-lock\"},{\"name\":\"release-tags-create\"},{\"name\":\"bot-branches\"}]" }
}

override_data {
  target = data.github_rest_api.rulesets_app
  values = { code = 200, body = "[{\"name\":\"app-main\"}]" }
}

# 인스턴스 override가 같은 자원의 전체 override보다 우선한다. writer 설치 저장소만 이름이 둘이다.
override_data {
  target = data.github_rest_api.rulesets_app["homelab-smoke"]
  values = { code = 200, body = "[{\"name\":\"app-main\"},{\"name\":\"bot-branches\"}]" }
}

override_data {
  target = data.github_rest_api.bypass_bot_branches
  values = { code = 200, body = "{\"bypass_actors\":[{\"actor_id\":1000003,\"actor_type\":\"Integration\",\"bypass_mode\":\"always\"}]}" }
}

override_data {
  target = data.github_rest_api.bypass_homelab["main-interim"]
  values = { code = 200, body = "{\"bypass_actors\":[{\"actor_id\":5,\"actor_type\":\"RepositoryRole\",\"bypass_mode\":\"pull_request\"}]}" }
}

override_data {
  target = data.github_rest_api.bypass_homelab["main-checks"]
  values = { code = 200, body = "{\"bypass_actors\":[]}" }
}

override_data {
  target = data.github_rest_api.bypass_homelab["main-review"]
  values = { code = 200, body = "{\"bypass_actors\":[{\"actor_id\":5,\"actor_type\":\"RepositoryRole\",\"bypass_mode\":\"pull_request\"},{\"actor_id\":1000002,\"actor_type\":\"Integration\",\"bypass_mode\":\"pull_request\"}]}" }
}

override_data {
  target = data.github_rest_api.bypass_homelab["deploy-branches"]
  values = { code = 200, body = "{\"bypass_actors\":[{\"actor_id\":1000001,\"actor_type\":\"Integration\",\"bypass_mode\":\"always\"}]}" }
}

override_data {
  target = data.github_rest_api.bypass_homelab["release-tags-lock"]
  values = { code = 200, body = "{\"bypass_actors\":[]}" }
}

override_data {
  target = data.github_rest_api.bypass_homelab["release-tags-create"]
  values = { code = 200, body = "{\"bypass_actors\":[{\"actor_id\":5,\"actor_type\":\"RepositoryRole\",\"bypass_mode\":\"always\"}]}" }
}

override_data {
  target = data.github_rest_api.bypass_app
  values = { code = 200, body = "{\"bypass_actors\":[{\"actor_id\":5,\"actor_type\":\"RepositoryRole\",\"bypass_mode\":\"pull_request\"}]}" }
}

override_data {
  target = data.github_rest_api.codeowners
  values = { code = 200, body = "{\"errors\":[]}" }
}

override_data {
  target = data.github_rest_api.codeowners_content
  values = { code = 200, body = "{\"content\":\"IyDsvZTrk5wg7IaM7Jyg7J6QCiogQHVra2llZQo=\"}" }
}

override_data {
  target = data.github_rest_api.branch_protection
  values = { code = 404, body = "{\"message\":\"Branch not protected\"}" }
}

override_data {
  target = data.github_rest_api.fork_approval_org
  values = { code = 200, body = "{\"approval_policy\":\"all_external_contributors\"}" }
}

override_data {
  target = data.github_rest_api.fork_approval
  values = { code = 200, body = "{\"approval_policy\":\"all_external_contributors\"}" }
}

override_data {
  target = data.github_rest_api.public_repos
  values = { code = 200, body = jsonencode(concat([for n in concat(["homelab", "homelab-app-template"], jsondecode(file("app-repos.json"))) : { name = n, archived = false }], [{ name = "old", archived = true }])) }
}

override_data {
  target = data.github_rest_api.automerge_policies
  values = { code = 200, body = "{\"total_count\":1,\"branch_policies\":[{\"name\":\"main\",\"type\":\"branch\"}]}" }
}

override_data {
  target = data.github_rest_api.automerge_secrets
  values = { code = 200, body = "{\"total_count\":1,\"secrets\":[{\"name\":\"HOMELAB_MERGE_KEY\"}]}" }
}

override_data {
  target = data.github_rest_api.repo_secrets
  values = { code = 200, body = "{\"total_count\":0,\"secrets\":[]}" }
}

override_data {
  target = data.github_rest_api.org_secrets
  values = { code = 200, body = "{\"total_count\":0,\"secrets\":[]}" }
}

run "all_guards_pass" {
  command = apply
}

run "sync_before_key_is_ok" {
  command = apply
  override_data {
    target = data.github_rest_api.automerge_secrets
    values = { code = 200, body = "{\"total_count\":0,\"secrets\":[]}" }
  }
}

run "g1_token_not_admin" {
  # 쓰기 권한 없는 토큰
  command = plan
  override_data {
    target = data.github_rest_api.token_admin
    values = { code = 200, body = "{\"permissions\":{\"admin\":false}}" }
  }
  expect_failures = [data.github_rest_api.token_admin]
}

run "g1_anonymous" {
  # 익명 폴백: permissions가 없다
  command = plan
  override_data {
    target = data.github_rest_api.token_admin
    values = { code = 200, body = "{\"name\":\"homelab\"}" }
  }
  expect_failures = [data.github_rest_api.token_admin]
}

run "g2_auto_merge_on" {
  command = plan
  override_data {
    target = data.github_rest_api.repo_homelab
    values = { code = 200, body = "{\"visibility\":\"public\",\"default_branch\":\"main\",\"allow_auto_merge\":true,\"allow_squash_merge\":true,\"allow_merge_commit\":false,\"allow_rebase_merge\":false,\"delete_branch_on_merge\":true,\"pull_request_creation_policy\":\"collaborators_only\"}" }
  }
  expect_failures = [data.github_rest_api.repo_homelab]
}

run "g2_merge_commit_on" {
  command = plan
  override_data {
    target = data.github_rest_api.repo_homelab
    values = { code = 200, body = "{\"visibility\":\"public\",\"default_branch\":\"main\",\"allow_auto_merge\":false,\"allow_squash_merge\":true,\"allow_merge_commit\":true,\"allow_rebase_merge\":false,\"delete_branch_on_merge\":true,\"pull_request_creation_policy\":\"collaborators_only\"}" }
  }
  expect_failures = [data.github_rest_api.repo_homelab]
}

run "g2_default_branch_homelab" {
  command = plan
  override_data {
    target = data.github_rest_api.repo_homelab
    values = { code = 200, body = "{\"visibility\":\"public\",\"default_branch\":\"develop\",\"allow_auto_merge\":false,\"allow_squash_merge\":true,\"allow_merge_commit\":false,\"allow_rebase_merge\":false,\"delete_branch_on_merge\":true,\"pull_request_creation_policy\":\"collaborators_only\"}" }
  }
  expect_failures = [data.github_rest_api.repo_homelab]
}

run "g2_default_branch_app" {
  command = plan
  override_data {
    target = data.github_rest_api.repo_app["files"]
    values = { code = 200, body = "{\"visibility\":\"public\",\"default_branch\":\"master\",\"security_and_analysis\":{\"secret_scanning\":{\"status\":\"enabled\"},\"secret_scanning_push_protection\":{\"status\":\"enabled\"}},\"pull_request_creation_policy\":\"collaborators_only\"}" }
  }
  expect_failures = [data.github_rest_api.repo_app]
}

run "g2_app_push_protection_off" {
  command = plan
  override_data {
    target = data.github_rest_api.repo_app["files"]
    values = { code = 200, body = "{\"visibility\":\"public\",\"default_branch\":\"main\",\"security_and_analysis\":{\"secret_scanning\":{\"status\":\"enabled\"},\"secret_scanning_push_protection\":{\"status\":\"disabled\"}},\"pull_request_creation_policy\":\"collaborators_only\"}" }
  }
  expect_failures = [data.github_rest_api.repo_app]
}

run "g2_app_private" {
  command = plan
  override_data {
    target = data.github_rest_api.repo_app["homelab-bot"]
    values = { code = 200, body = "{\"visibility\":\"private\",\"default_branch\":\"main\",\"security_and_analysis\":{\"secret_scanning\":{\"status\":\"enabled\"},\"secret_scanning_push_protection\":{\"status\":\"enabled\"}},\"pull_request_creation_policy\":\"collaborators_only\"}" }
  }
  expect_failures = [data.github_rest_api.repo_app]
}

run "g2_listed_not_created" {
  # app-repos.json에 넣고 저장소를 아직 만들지 않은 사이. 저장소 GET이 404라 plan이 멈춘다(apply까지 가지 않는다).
  command = plan
  override_data {
    target = data.github_rest_api.repo_app["homelab-probe"]
    values = { code = 404, body = "{\"message\":\"Not Found\"}" }
  }
  expect_failures = [data.github_rest_api.repo_app]
}

run "g2_pvr_off" {
  command = plan
  override_data {
    target = data.github_rest_api.private_vulnerability_reporting["homelab-app-template"]
    values = { code = 200, body = "{\"enabled\":false}" }
  }
  expect_failures = [data.github_rest_api.private_vulnerability_reporting]
}

run "g2_pr_creation_all_homelab" {
  command = plan
  override_data {
    target = data.github_rest_api.repo_homelab
    values = { code = 200, body = "{\"visibility\":\"public\",\"default_branch\":\"main\",\"allow_auto_merge\":false,\"allow_squash_merge\":true,\"allow_merge_commit\":false,\"allow_rebase_merge\":false,\"delete_branch_on_merge\":true,\"pull_request_creation_policy\":\"all\"}" }
  }
  expect_failures = [data.github_rest_api.repo_homelab]
}

run "g2_pr_creation_all_app" {
  command = plan
  override_data {
    target = data.github_rest_api.repo_app["homelab-probe"]
    values = { code = 200, body = "{\"visibility\":\"public\",\"default_branch\":\"main\",\"security_and_analysis\":{\"secret_scanning\":{\"status\":\"enabled\"},\"secret_scanning_push_protection\":{\"status\":\"enabled\"}},\"pull_request_creation_policy\":\"all\"}" }
  }
  expect_failures = [data.github_rest_api.repo_app]
}

run "g2_pr_creation_field_missing" {
  # 문서에 없는 필드라 이름이 바뀌면 응답에서 빠진다. 막는 쪽으로 실패해야 한다.
  command = plan
  override_data {
    target = data.github_rest_api.repo_app["files"]
    values = { code = 200, body = "{\"visibility\":\"public\",\"default_branch\":\"main\",\"security_and_analysis\":{\"secret_scanning\":{\"status\":\"enabled\"},\"secret_scanning_push_protection\":{\"status\":\"enabled\"}}}" }
  }
  expect_failures = [data.github_rest_api.repo_app]
}

run "g2_interaction_limit_none_empty" {
  # limit이 없으면 빈 응답(문서). 빈 본문과 {} 둘 다 본다.
  command = plan
  override_data {
    target = data.github_rest_api.interaction_limit_org
    values = { code = 200, body = "" }
  }
  expect_failures = [data.github_rest_api.interaction_limit_org]
}

run "g2_interaction_limit_none_object" {
  command = plan
  override_data {
    target = data.github_rest_api.interaction_limit_org
    values = { code = 200, body = "{}" }
  }
  expect_failures = [data.github_rest_api.interaction_limit_org]
}

run "g2_interaction_limit_contributors" {
  command = plan
  override_data {
    target = data.github_rest_api.interaction_limit_org
    values = { code = 200, body = "{\"limit\":\"contributors_only\",\"origin\":\"organization\",\"expires_at\":\"2999-01-01T00:00:00Z\"}" }
  }
  expect_failures = [data.github_rest_api.interaction_limit_org]
}

run "g2_interaction_limit_expired" {
  command = plan
  override_data {
    target = data.github_rest_api.interaction_limit_org
    values = { code = 200, body = "{\"limit\":\"collaborators_only\",\"origin\":\"organization\",\"expires_at\":\"2020-01-01T00:00:00Z\"}" }
  }
  expect_failures = [data.github_rest_api.interaction_limit_org]
}

run "g2_interaction_limit_within_45d" {
  # 지금+44일. 아직 유효하지만 45일 안이라 멈춘다. 시험 파일에는 plantimestamp()가 없어 timestamp()로 만든다(경계 양쪽 1일 여유).
  command = plan
  override_data {
    target = data.github_rest_api.interaction_limit_org
    values = { code = 200, body = jsonencode({ limit = "collaborators_only", origin = "organization", expires_at = timeadd(timestamp(), "1056h") }) }
  }
  expect_failures = [data.github_rest_api.interaction_limit_org]
}

run "g2_interaction_limit_after_45d" {
  # 지금+46일은 통과한다(경계 반대쪽).
  command = plan
  override_data {
    target = data.github_rest_api.interaction_limit_org
    values = { code = 200, body = jsonencode({ limit = "collaborators_only", origin = "organization", expires_at = timeadd(timestamp(), "1104h") }) }
  }
}

run "g3_extra_ruleset" {
  # 선언 밖 ruleset(disabled여도)
  command   = apply
  state_key = "g3_extra_ruleset"
  override_data {
    target = data.github_rest_api.rulesets_homelab
    values = { code = 200, body = "[{\"name\":\"main-interim\"},{\"name\":\"main-checks\"},{\"name\":\"main-review\"},{\"name\":\"deploy-branches\"},{\"name\":\"release-tags-lock\"},{\"name\":\"release-tags-create\"},{\"name\":\"bot-branches\"},{\"name\":\"probe\"}]" }
  }
  expect_failures = [data.github_rest_api.rulesets_homelab]
}

run "g3_duplicate_name" {
  # 같은 이름 둘
  command   = apply
  state_key = "g3_duplicate_name"
  override_data {
    target = data.github_rest_api.rulesets_homelab
    values = { code = 200, body = "[{\"name\":\"main-interim\"},{\"name\":\"main-checks\"},{\"name\":\"main-review\"},{\"name\":\"main-review\"},{\"name\":\"deploy-branches\"},{\"name\":\"release-tags-lock\"},{\"name\":\"release-tags-create\"},{\"name\":\"bot-branches\"}]" }
  }
  expect_failures = [data.github_rest_api.rulesets_homelab]
}

run "g3_homelab_without_bot_branches" {
  # homelab에 설치했는데 E가 빠졌다. 그대로 두면 아무 신원이나 homelab의 bot/ 브랜치를 덮는다.
  command = plan
  override_data {
    target = data.github_rest_api.rulesets_homelab
    values = { code = 200, body = "[{\"name\":\"main-interim\"},{\"name\":\"main-checks\"},{\"name\":\"main-review\"},{\"name\":\"deploy-branches\"},{\"name\":\"release-tags-lock\"},{\"name\":\"release-tags-create\"}]" }
  }
  expect_failures = [data.github_rest_api.rulesets_homelab]
}

run "g3_homelab_duplicate_bot_branches" {
  command = plan
  override_data {
    target = data.github_rest_api.rulesets_homelab
    values = { code = 200, body = "[{\"name\":\"main-interim\"},{\"name\":\"main-checks\"},{\"name\":\"main-review\"},{\"name\":\"deploy-branches\"},{\"name\":\"release-tags-lock\"},{\"name\":\"release-tags-create\"},{\"name\":\"bot-branches\"},{\"name\":\"bot-branches\"}]" }
  }
  expect_failures = [data.github_rest_api.rulesets_homelab]
}

run "g3_homelab_any_order" {
  # GitHub의 목록 순서에 기대지 않는다.
  command = plan
  override_data {
    target = data.github_rest_api.rulesets_homelab
    values = { code = 200, body = "[{\"name\":\"bot-branches\"},{\"name\":\"release-tags-create\"},{\"name\":\"release-tags-lock\"},{\"name\":\"deploy-branches\"},{\"name\":\"main-review\"},{\"name\":\"main-checks\"},{\"name\":\"main-interim\"}]" }
  }
}

run "g3_homelab_waits_for_bot_branches_change" {
  # E만 바뀌어도 homelab의 guard 3은 apply 뒤로 미뤄진다. depends_on에서 E가 빠지면 망가진 응답을 plan 때 읽어 이 run이 실패한다.
  # 첫 apply가 이 경우다. E가 없는 응답을 plan에서 읽어 멈추면 E를 만들 수 없다.
  command = plan
  variables {
    homelab_writer_app_id = 1000009
  }
  override_data {
    target = data.github_rest_api.bypass_bot_branches
    values = { code = 200, body = "{\"bypass_actors\":[{\"actor_id\":1000009,\"actor_type\":\"Integration\",\"bypass_mode\":\"always\"}]}" }
  }
  override_data {
    target = data.github_rest_api.rulesets_homelab
    values = { code = 200, body = "[{\"name\":\"main-interim\"},{\"name\":\"main-checks\"},{\"name\":\"main-review\"},{\"name\":\"deploy-branches\"},{\"name\":\"release-tags-lock\"},{\"name\":\"release-tags-create\"}]" }
  }
}

run "g3_app_extra" {
  command = plan
  override_data {
    target = data.github_rest_api.rulesets_app["files"]
    values = { code = 200, body = "[{\"name\":\"app-main\"},{\"name\":\"other\"}]" }
  }
  expect_failures = [data.github_rest_api.rulesets_app]
}

run "g3_writer_repo_without_bot_branches" {
  # 설치 저장소에서 E가 빠졌다. 그대로 두면 아무 신원이나 bot/ 브랜치를 덮는다.
  command = plan
  override_data {
    target = data.github_rest_api.rulesets_app["homelab-smoke"]
    values = { code = 200, body = "[{\"name\":\"app-main\"}]" }
  }
  expect_failures = [data.github_rest_api.rulesets_app]
}

run "g3_writer_repo_without_app_main" {
  command = plan
  override_data {
    target = data.github_rest_api.rulesets_app["homelab-smoke"]
    values = { code = 200, body = "[{\"name\":\"bot-branches\"}]" }
  }
  expect_failures = [data.github_rest_api.rulesets_app]
}

run "g3_writer_repo_extra" {
  command = plan
  override_data {
    target = data.github_rest_api.rulesets_app["homelab-smoke"]
    values = { code = 200, body = "[{\"name\":\"app-main\"},{\"name\":\"bot-branches\"},{\"name\":\"other\"}]" }
  }
  expect_failures = [data.github_rest_api.rulesets_app]
}

run "g3_writer_repo_duplicate" {
  command = plan
  override_data {
    target = data.github_rest_api.rulesets_app["homelab-smoke"]
    values = { code = 200, body = "[{\"name\":\"app-main\"},{\"name\":\"bot-branches\"},{\"name\":\"bot-branches\"}]" }
  }
  expect_failures = [data.github_rest_api.rulesets_app]
}

run "g3_writer_repo_any_order" {
  # GitHub의 목록 순서에 기대지 않는다.
  command = plan
  override_data {
    target = data.github_rest_api.rulesets_app["homelab-smoke"]
    values = { code = 200, body = "[{\"name\":\"bot-branches\"},{\"name\":\"app-main\"}]" }
  }
}

run "g3_other_app_has_bot_branches" {
  # 설치하지 않은 앱 저장소의 bot-branches는 선언 밖 ruleset이다.
  command = plan
  override_data {
    target = data.github_rest_api.rulesets_app["files"]
    values = { code = 200, body = "[{\"name\":\"app-main\"},{\"name\":\"bot-branches\"}]" }
  }
  expect_failures = [data.github_rest_api.rulesets_app]
}

run "g3_template_has_bot_branches" {
  command = plan
  override_data {
    target = data.github_rest_api.rulesets_app["homelab-app-template"]
    values = { code = 200, body = "[{\"name\":\"app-main\"},{\"name\":\"bot-branches\"}]" }
  }
  expect_failures = [data.github_rest_api.rulesets_app]
}

run "g3_waits_for_bot_branches_change" {
  # E만 바뀌어도 guard 3은 apply 뒤로 미뤄진다. depends_on에서 E가 빠지면 망가진 응답을 plan 때 읽어 이 run이 실패한다.
  # guard 4는 이 변경과 상관없이 통과하도록 바뀐 App ID로 응답을 맞춘다.
  command = plan
  variables {
    homelab_writer_app_id = 1000009
  }
  override_data {
    target = data.github_rest_api.bypass_bot_branches
    values = { code = 200, body = "{\"bypass_actors\":[{\"actor_id\":1000009,\"actor_type\":\"Integration\",\"bypass_mode\":\"always\"}]}" }
  }
  override_data {
    target = data.github_rest_api.rulesets_app["homelab-smoke"]
    values = { code = 200, body = "[{\"name\":\"app-main\"}]" }
  }
}

run "g4_checks_bypass" {
  # 필수 검사에 bypass
  command = plan
  override_data {
    target = data.github_rest_api.bypass_homelab["main-checks"]
    values = { code = 200, body = "{\"bypass_actors\":[{\"actor_id\":5,\"actor_type\":\"RepositoryRole\",\"bypass_mode\":\"pull_request\"}]}" }
  }
  expect_failures = [data.github_rest_api.bypass_homelab]
}

run "g4_exempt" {
  # exempt는 규칙을 돌리지 않고 기록도 없다
  command   = apply
  state_key = "g4_exempt"
  override_data {
    target = data.github_rest_api.bypass_homelab["main-review"]
    values = { code = 200, body = "{\"bypass_actors\":[{\"actor_id\":5,\"actor_type\":\"RepositoryRole\",\"bypass_mode\":\"exempt\"},{\"actor_id\":1000002,\"actor_type\":\"Integration\",\"bypass_mode\":\"pull_request\"}]}" }
  }
  expect_failures = [data.github_rest_api.bypass_homelab]
}

run "g4_codex_in_bypass" {
  # 다른 App(Codex Connector 등)이 bypass에 들어감(D-26 조건 (1))
  command   = apply
  state_key = "g4_codex_in_bypass"
  override_data {
    target = data.github_rest_api.bypass_homelab["main-review"]
    values = { code = 200, body = "{\"bypass_actors\":[{\"actor_id\":5,\"actor_type\":\"RepositoryRole\",\"bypass_mode\":\"pull_request\"},{\"actor_id\":1000002,\"actor_type\":\"Integration\",\"bypass_mode\":\"pull_request\"},{\"actor_id\":999,\"actor_type\":\"Integration\",\"bypass_mode\":\"always\"}]}" }
  }
  expect_failures = [data.github_rest_api.bypass_homelab]
}

run "g4_no_bypass_field" {
  # 쓰기 권한 없는 토큰에는 bypass_actors가 없다
  command   = apply
  state_key = "g4_no_bypass_field"
  override_data {
    target = data.github_rest_api.bypass_homelab["release-tags-lock"]
    values = { code = 200, body = "{\"name\":\"release-tags-lock\"}" }
  }
  expect_failures = [data.github_rest_api.bypass_homelab]
}

run "g4_app_main_app_bypass" {
  command = plan
  override_data {
    target = data.github_rest_api.bypass_app["homelab-bot"]
    values = { code = 200, body = "{\"bypass_actors\":[{\"actor_id\":5,\"actor_type\":\"RepositoryRole\",\"bypass_mode\":\"pull_request\"},{\"actor_id\":1000001,\"actor_type\":\"Integration\",\"bypass_mode\":\"always\"}]}" }
  }
  expect_failures = [data.github_rest_api.bypass_app]
}

run "g4_writer_bypass_copied_to_app_main" {
  # E의 bypass를 앱 main에 복사하면 writer가 앱 main에 직접 쓴다.
  command = plan
  override_data {
    target = data.github_rest_api.bypass_app["homelab-smoke"]
    values = { code = 200, body = "{\"bypass_actors\":[{\"actor_id\":5,\"actor_type\":\"RepositoryRole\",\"bypass_mode\":\"pull_request\"},{\"actor_id\":1000003,\"actor_type\":\"Integration\",\"bypass_mode\":\"always\"}]}" }
  }
  expect_failures = [data.github_rest_api.bypass_app]
}

run "g4_bot_branches_extra_actor" {
  # 다른 App이 더 들어옴
  command = plan
  override_data {
    target = data.github_rest_api.bypass_bot_branches["homelab-smoke"]
    values = { code = 200, body = "{\"bypass_actors\":[{\"actor_id\":1000003,\"actor_type\":\"Integration\",\"bypass_mode\":\"always\"},{\"actor_id\":999,\"actor_type\":\"Integration\",\"bypass_mode\":\"always\"}]}" }
  }
  expect_failures = [data.github_rest_api.bypass_bot_branches]
}

run "g4_bot_branches_admin_actor" {
  # 관리자 역할도 E를 우회하지 않는다.
  command = plan
  override_data {
    target = data.github_rest_api.bypass_bot_branches["homelab-smoke"]
    values = { code = 200, body = "{\"bypass_actors\":[{\"actor_id\":1000003,\"actor_type\":\"Integration\",\"bypass_mode\":\"always\"},{\"actor_id\":5,\"actor_type\":\"RepositoryRole\",\"bypass_mode\":\"always\"}]}" }
  }
  expect_failures = [data.github_rest_api.bypass_bot_branches]
}

run "g4_bot_branches_other_app" {
  # 다른 App으로 바뀜(Integration 종류와 모드는 같다)
  command = plan
  override_data {
    target = data.github_rest_api.bypass_bot_branches["homelab-smoke"]
    values = { code = 200, body = "{\"bypass_actors\":[{\"actor_id\":999,\"actor_type\":\"Integration\",\"bypass_mode\":\"always\"}]}" }
  }
  expect_failures = [data.github_rest_api.bypass_bot_branches]
}

run "g4_bot_branches_pull_request_mode" {
  # 모드가 다르면 게시 서버의 브랜치 push가 막힌다.
  command = plan
  override_data {
    target = data.github_rest_api.bypass_bot_branches["homelab-smoke"]
    values = { code = 200, body = "{\"bypass_actors\":[{\"actor_id\":1000003,\"actor_type\":\"Integration\",\"bypass_mode\":\"pull_request\"}]}" }
  }
  expect_failures = [data.github_rest_api.bypass_bot_branches]
}

run "g4_bot_branches_exempt" {
  command = plan
  override_data {
    target = data.github_rest_api.bypass_bot_branches["homelab-smoke"]
    values = { code = 200, body = "{\"bypass_actors\":[{\"actor_id\":1000003,\"actor_type\":\"Integration\",\"bypass_mode\":\"exempt\"}]}" }
  }
  expect_failures = [data.github_rest_api.bypass_bot_branches]
}

run "g4_bot_branches_no_actor" {
  command = plan
  override_data {
    target = data.github_rest_api.bypass_bot_branches["homelab-smoke"]
    values = { code = 200, body = "{\"bypass_actors\":[]}" }
  }
  expect_failures = [data.github_rest_api.bypass_bot_branches]
}

run "g4_bot_branches_no_bypass_field" {
  # 쓰기 권한 없는 토큰에는 bypass_actors가 없다
  command = plan
  override_data {
    target = data.github_rest_api.bypass_bot_branches["homelab-smoke"]
    values = { code = 200, body = "{\"name\":\"bot-branches\"}" }
  }
  expect_failures = [data.github_rest_api.bypass_bot_branches]
}

run "g4_bot_branches_after_apply" {
  # 빈 state에서는 E 생성이 예정돼 있어 guard 4가 apply 뒤에 평가된다.
  command   = apply
  state_key = "g4_bot_branches_after_apply"
  override_data {
    target = data.github_rest_api.bypass_bot_branches["homelab-smoke"]
    values = { code = 200, body = "{\"bypass_actors\":[{\"actor_id\":999,\"actor_type\":\"Integration\",\"bypass_mode\":\"always\"}]}" }
  }
  expect_failures = [data.github_rest_api.bypass_bot_branches]
}

run "g4_homelab_bot_branches_other_app" {
  # 다른 App으로 바뀜(Integration 종류와 모드는 같다)
  command = plan
  override_data {
    target = data.github_rest_api.bypass_bot_branches["homelab"]
    values = { code = 200, body = "{\"bypass_actors\":[{\"actor_id\":999,\"actor_type\":\"Integration\",\"bypass_mode\":\"always\"}]}" }
  }
  expect_failures = [data.github_rest_api.bypass_bot_branches]
}

run "g4_homelab_bot_branches_admin_actor" {
  # 관리자 역할도 E를 우회하지 않는다.
  command = plan
  override_data {
    target = data.github_rest_api.bypass_bot_branches["homelab"]
    values = { code = 200, body = "{\"bypass_actors\":[{\"actor_id\":1000003,\"actor_type\":\"Integration\",\"bypass_mode\":\"always\"},{\"actor_id\":5,\"actor_type\":\"RepositoryRole\",\"bypass_mode\":\"always\"}]}" }
  }
  expect_failures = [data.github_rest_api.bypass_bot_branches]
}

run "g4_homelab_bot_branches_pull_request_mode" {
  # 모드가 다르면 writer의 브랜치 push가 막힌다.
  command = plan
  override_data {
    target = data.github_rest_api.bypass_bot_branches["homelab"]
    values = { code = 200, body = "{\"bypass_actors\":[{\"actor_id\":1000003,\"actor_type\":\"Integration\",\"bypass_mode\":\"pull_request\"}]}" }
  }
  expect_failures = [data.github_rest_api.bypass_bot_branches]
}

run "g4_homelab_bot_branches_exempt" {
  command = plan
  override_data {
    target = data.github_rest_api.bypass_bot_branches["homelab"]
    values = { code = 200, body = "{\"bypass_actors\":[{\"actor_id\":1000003,\"actor_type\":\"Integration\",\"bypass_mode\":\"exempt\"}]}" }
  }
  expect_failures = [data.github_rest_api.bypass_bot_branches]
}

run "g4_homelab_bot_branches_no_actor" {
  command = plan
  override_data {
    target = data.github_rest_api.bypass_bot_branches["homelab"]
    values = { code = 200, body = "{\"bypass_actors\":[]}" }
  }
  expect_failures = [data.github_rest_api.bypass_bot_branches]
}

run "g4_homelab_bot_branches_after_apply" {
  # 빈 state에서는 E 생성이 예정돼 있어 guard 4가 apply 뒤에 평가된다.
  command   = apply
  state_key = "g4_homelab_bot_branches_after_apply"
  override_data {
    target = data.github_rest_api.bypass_bot_branches["homelab"]
    values = { code = 200, body = "{\"bypass_actors\":[{\"actor_id\":999,\"actor_type\":\"Integration\",\"bypass_mode\":\"always\"}]}" }
  }
  expect_failures = [data.github_rest_api.bypass_bot_branches]
}

run "g4_writer_bypass_copied_to_main_review" {
  # E의 bypass를 main에 복사하면 writer가 homelab main에 직접 쓰고, Argo CD가 그것을 곧 적용한다.
  command = plan
  override_data {
    target = data.github_rest_api.bypass_homelab["main-review"]
    values = { code = 200, body = "{\"bypass_actors\":[{\"actor_id\":5,\"actor_type\":\"RepositoryRole\",\"bypass_mode\":\"pull_request\"},{\"actor_id\":1000002,\"actor_type\":\"Integration\",\"bypass_mode\":\"pull_request\"},{\"actor_id\":1000003,\"actor_type\":\"Integration\",\"bypass_mode\":\"always\"}]}" }
  }
  expect_failures = [data.github_rest_api.bypass_homelab]
}

run "g4_writer_bypass_copied_to_main_checks" {
  command = plan
  override_data {
    target = data.github_rest_api.bypass_homelab["main-checks"]
    values = { code = 200, body = "{\"bypass_actors\":[{\"actor_id\":1000003,\"actor_type\":\"Integration\",\"bypass_mode\":\"always\"}]}" }
  }
  expect_failures = [data.github_rest_api.bypass_homelab]
}

run "g4_writer_bypass_copied_to_deploy_branches" {
  # deploy/를 만들 수 있으면 조건 2의 브랜치 검사가 이 신원을 막지 못한다. 남는 것은 조건 1뿐이다.
  command = plan
  override_data {
    target = data.github_rest_api.bypass_homelab["deploy-branches"]
    values = { code = 200, body = "{\"bypass_actors\":[{\"actor_id\":1000001,\"actor_type\":\"Integration\",\"bypass_mode\":\"always\"},{\"actor_id\":1000003,\"actor_type\":\"Integration\",\"bypass_mode\":\"always\"}]}" }
  }
  expect_failures = [data.github_rest_api.bypass_homelab]
}

run "g5_no_codeowners" {
  command = plan
  override_data {
    target = data.github_rest_api.codeowners["homelab-app-template"]
    values = { code = 404, body = "{\"message\":\"Not Found\"}" }
  }
  expect_failures = [data.github_rest_api.codeowners]
}

run "g5_codeowners_errors" {
  command = plan
  override_data {
    target = data.github_rest_api.codeowners["homelab"]
    values = { code = 200, body = "{\"errors\":[{\"line\":1,\"kind\":\"Unknown owner\"}]}" }
  }
  expect_failures = [data.github_rest_api.codeowners]
}

run "g6_branch_protection" {
  command = plan
  override_data {
    target = data.github_rest_api.branch_protection["files"]
    values = { code = 200, body = "{\"url\":\"x\"}" }
  }
  expect_failures = [data.github_rest_api.branch_protection]
}

run "g7_org_first_time" {
  command = plan
  override_data {
    target = data.github_rest_api.fork_approval_org
    values = { code = 200, body = "{\"approval_policy\":\"first_time_contributors\"}" }
  }
  expect_failures = [data.github_rest_api.fork_approval_org]
}

run "g7_repo_first_time" {
  command = plan
  override_data {
    target = data.github_rest_api.fork_approval["homelab"]
    values = { code = 200, body = "{\"approval_policy\":\"first_time_contributors\"}" }
  }
  expect_failures = [data.github_rest_api.fork_approval]
}

run "g8_unlisted_public" {
  # 목록 밖 public 저장소(목록은 전부 있고 하나가 더 있다). 더하는 이름은 목록 이름을 모두 이어 붙여 어느 목록 이름보다
  # 길다. 목록에 이미 있는 이름이면 목록 밖이 아니라 중복을 시험하게 된다.
  command = plan
  override_data {
    target = data.github_rest_api.public_repos
    values = { code = 200, body = jsonencode([for n in concat(["homelab", "homelab-app-template", "unlisted-${join("-", jsondecode(file("app-repos.json")))}"], jsondecode(file("app-repos.json"))) : { name = n, archived = false }]) }
  }
  expect_failures = [data.github_rest_api.public_repos]
}

run "g8_listed_missing" {
  # 목록의 앱 저장소 하나가 public이 아니거나 아직 없다(목록 PR 병합 뒤 저장소 생성 전). 실제 plan·verify는 이때 멈춘다.
  command = plan
  override_data {
    target = data.github_rest_api.public_repos
    values = { code = 200, body = jsonencode([for n in concat(["homelab", "homelab-app-template"], jsondecode(file("app-repos.json"))) : { name = n, archived = false } if n != jsondecode(file("app-repos.json"))[0]]) }
  }
  expect_failures = [data.github_rest_api.public_repos]
}

run "g9_policy_extra" {
  command   = apply
  state_key = "g9_policy_extra"
  override_data {
    target = data.github_rest_api.automerge_policies
    values = { code = 200, body = "{\"total_count\":2,\"branch_policies\":[{\"name\":\"main\",\"type\":\"branch\"},{\"name\":\"*\",\"type\":\"branch\"}]}" }
  }
  expect_failures = [data.github_rest_api.automerge_policies]
}

run "g9_policy_tag" {
  command   = apply
  state_key = "g9_policy_tag"
  override_data {
    target = data.github_rest_api.automerge_policies
    values = { code = 200, body = "{\"total_count\":1,\"branch_policies\":[{\"name\":\"main\",\"type\":\"tag\"}]}" }
  }
  expect_failures = [data.github_rest_api.automerge_policies]
}

run "g9_env_extra_secret" {
  command   = apply
  state_key = "g9_env_extra_secret"
  override_data {
    target = data.github_rest_api.automerge_secrets
    values = { code = 200, body = "{\"total_count\":2,\"secrets\":[{\"name\":\"HOMELAB_MERGE_KEY\"},{\"name\":\"OTHER\"}]}" }
  }
  expect_failures = [data.github_rest_api.automerge_secrets]
}

run "g9_repo_secret" {
  # Sync 범위를 Repository로 잘못 만듦
  command = plan
  override_data {
    target = data.github_rest_api.repo_secrets
    values = { code = 200, body = "{\"total_count\":1,\"secrets\":[{\"name\":\"HOMELAB_MERGE_KEY\"}]}" }
  }
  expect_failures = [data.github_rest_api.repo_secrets]
}

run "g9_org_secret" {
  # Sync 범위를 Organization으로 잘못 만듦
  command = plan
  override_data {
    target = data.github_rest_api.org_secrets
    values = { code = 200, body = "{\"total_count\":1,\"secrets\":[{\"name\":\"HOMELAB_MERGE_KEY\"}]}" }
  }
  expect_failures = [data.github_rest_api.org_secrets]
}

run "app_id_placeholder" {
  # App ID를 채우지 않으면 plan이 멈춘다.
  command = plan
  variables {
    homelab_deploy_app_id = 0
  }
  expect_failures = [var.homelab_deploy_app_id]
}

run "writer_app_id_placeholder" {
  command = plan
  variables {
    homelab_writer_app_id = 0
  }
  expect_failures = [var.homelab_writer_app_id]
}

run "g5_codeowners_partial" {
  # 오류 없는 파일이지만 /docs/만 소유한다.
  command = plan
  override_data {
    target = data.github_rest_api.codeowners_content["files"]
    values = { code = 200, body = "{\"content\":\"L2RvY3MvIEB1a2tpZWUK\"}" }
  }
  expect_failures = [data.github_rest_api.codeowners_content]
}

run "g5_codeowners_override" {
  # 뒤 줄이 /src/를 다른 소유자로 덮는다.
  command = plan
  override_data {
    target = data.github_rest_api.codeowners_content["homelab"]
    values = { code = 200, body = "{\"content\":\"KiBAdWtraWVlCi9zcmMvIEBzb21lb25lCg==\"}" }
  }
  expect_failures = [data.github_rest_api.codeowners_content]
}

run "main_update_restricted" {
  # main 갱신은 bypass 신원만(Restrict updates, U08 (나)). 승인 요건만으로는 owner PR의 App 승인 병합을 막지 못한다.
  command = plan
  assert {
    condition     = github_repository_ruleset.main_review.rules[0].update == true
    error_message = "main-review에 update 규칙이 없다."
  }
  assert {
    condition     = alltrue([for r in github_repository_ruleset.app_main : r.rules[0].update == true])
    error_message = "app-main 중 update 규칙이 없는 저장소가 있다."
  }
  assert {
    condition     = !coalesce(github_repository_ruleset.main_review.rules[0].update_allows_fetch_and_merge, false) && alltrue([for r in github_repository_ruleset.app_main : !coalesce(r.rules[0].update_allows_fetch_and_merge, false)])
    error_message = "update_allows_fetch_and_merge를 켜지 않는다."
  }
}

run "bot_branches_shape" {
  # guard 4는 bypass만 본다. 대상과 규칙은 선언을 직접 확인한다. 끝의 `**`만 두면 bot/x/y가 빠진다(FNM_PATHNAME).
  command = plan
  assert {
    condition     = jsonencode(sort(keys(github_repository_ruleset.bot_branches))) == jsonencode(["homelab", "homelab-smoke"])
    error_message = "bot-branches가 설치 저장소 homelab·homelab-smoke 둘에만 있는 것이 아니다."
  }
  assert {
    condition     = alltrue([for r in github_repository_ruleset.bot_branches : r.name == "bot-branches" && r.target == "branch" && r.enforcement == "active"])
    error_message = "bot-branches의 이름·대상 종류·enforcement가 다르다."
  }
  assert {
    condition     = alltrue([for r in github_repository_ruleset.bot_branches : jsonencode(r.conditions[0].ref_name[0].include) == jsonencode(["refs/heads/bot/**", "refs/heads/bot/**/*"]) && length(r.conditions[0].ref_name[0].exclude) == 0])
    error_message = "bot-branches의 대상 패턴이 bot/**와 bot/**/* 둘이 아니다."
  }
  assert {
    condition     = alltrue([for r in github_repository_ruleset.bot_branches : r.rules[0].creation == true && r.rules[0].update == true && r.rules[0].deletion == true])
    error_message = "bot-branches에 생성·갱신·삭제 제한 중 빠진 것이 있다."
  }
  assert {
    condition     = alltrue([for r in github_repository_ruleset.bot_branches : jsonencode([for a in r.bypass_actors : "${a.actor_type}:${a.actor_id}:${a.bypass_mode}"]) == jsonencode(["Integration:1000003:always"])])
    error_message = "bot-branches의 선언된 bypass가 ukyi-writer App(always) 하나가 아니다."
  }
}

run "writer_bypass_only_in_bot_branches" {
  # guard 4는 실제 응답을 표와 비교하므로 표가 틀리면 복사된 bypass를 통과시킨다. 표와 선언을 직접 확인한다.
  command = plan
  assert {
    condition     = !contains(keys(local.homelab_bypass), "bot-branches")
    error_message = "homelab_bypass에 bot-branches를 넣지 않는다. E의 bypass는 bypass_bot_branches가 본다."
  }
  assert {
    condition     = !anytrue([for k, v in local.homelab_bypass : anytrue([for a in v : strcontains(a, "Integration:${var.homelab_writer_app_id}:")])])
    error_message = "homelab_bypass에 writer App이 있다."
  }
  assert {
    condition = !anytrue([for r in [
      github_repository_ruleset.main_interim,
      github_repository_ruleset.main_checks,
      github_repository_ruleset.main_review,
      github_repository_ruleset.deploy_branches,
      github_repository_ruleset.release_tags_lock,
      github_repository_ruleset.release_tags_create,
    ] : anytrue([for a in r.bypass_actors : a.actor_type == "Integration" && a.actor_id == var.homelab_writer_app_id])])
    error_message = "homelab의 main·deploy·태그 ruleset 선언에 writer App bypass가 있다."
  }
}

run "writer_repos_allowlist" {
  # 시험에서 locals를 바꿀 수 없어, precondition이 쓰는 허용 목록 자체를 본다.
  command = plan
  assert {
    condition     = contains(local.writer_allowed_repos, "homelab") && contains(local.writer_allowed_repos, "homelab-smoke")
    error_message = "homelab·homelab-smoke가 E 허용 목록에 없다."
  }
  assert {
    condition     = !contains(local.writer_allowed_repos, "homelab-app-template")
    error_message = "템플릿에는 writer를 설치하지 않는다(D-24)."
  }
  assert {
    condition     = !contains(local.writer_allowed_repos, "homelab-typo")
    error_message = "목록 밖 이름이 허용됐다."
  }
  assert {
    condition     = length(setsubtract(local.writer_repos, local.writer_allowed_repos)) == 0
    error_message = "writer_repos에 허용 목록 밖 저장소가 있다."
  }
  assert {
    condition     = !contains(local.app_repos, "homelab")
    error_message = "homelab을 app-repos.json에 넣어 우회하지 않는다."
  }
}
