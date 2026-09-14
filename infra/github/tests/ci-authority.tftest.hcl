# mock provider만 사용한다. HCL의 실제 resolved plan을 검증하며 서버의 거부 증거는 아니다.
mock_provider "github" {
  mock_data "github_repository" {
    defaults = {
      name    = "homelab"
      node_id = "R_kgDOS2ctrg"
    }
  }
}

variables {
  github_owner       = "ukyi-app"
  github_token       = "fake-test-token"
  telegram_bot_token = "fake-test-token"
  telegram_chat_id   = "fake-test-chat"
}

run "main_environment_is_branch_only" {
  command = plan
  assert {
    condition = (
      github_repository_environment.main.environment == "homelab-main" &&
      github_repository_environment.main.can_admins_bypass == false &&
      github_repository_environment.main.deployment_branch_policy[0].protected_branches == false &&
      github_repository_environment.main.deployment_branch_policy[0].custom_branch_policies == true &&
      github_repository_environment_deployment_policy.main.branch_pattern == "main" &&
      github_repository_environment_deployment_policy.main.tag_pattern == null
    )
    error_message = "main branch 한 개만 허용해야 한다. tag main·PR refs·aiops/* 추가는 허용하지 않는다."
  }
  assert {
    condition = (
      github_actions_environment_secret.telegram_bot_token.environment == "homelab-main" &&
      github_actions_environment_secret.telegram_chat_id.environment == "homelab-main"
    )
    error_message = "Terraform이 Telegram을 repository 범위로 다시 공급하면 안 된다."
  }
}

run "main_update_allows_only_owner_and_existing_writer" {
  command = plan
  assert {
    condition = (
      github_branch_protection.main.pattern == "main" &&
      github_branch_protection.main.restrict_pushes[0].blocks_creations == true &&
      toset(github_branch_protection.main.restrict_pushes[0].push_allowances) == toset(["MDQ6VXNlcjUyMzcxNTI5", "A_kwHOEWo9us4APbFI"]) &&
      github_branch_protection.main.required_status_checks[0].strict == true &&
      toset(github_branch_protection.main.required_status_checks[0].contexts) == toset(["gate"]) &&
      github_branch_protection.main.required_pull_request_reviews[0].required_approving_review_count == 0 &&
      github_branch_protection.main.enforce_admins == false &&
      github_branch_protection.main.allows_force_pushes == false &&
      github_branch_protection.main.allows_deletions == false
    )
    error_message = "owner와 writer App만 명시 허용하고 gate 단일·PR-first·수동 admin 잔여를 유지해야 한다."
  }
}

run "sweeper_refs_require_writer_identity" {
  command = plan
  assert {
    condition = (
      github_repository_ruleset.mutation_writer_only.enforcement == "active" &&
      github_repository_ruleset.mutation_writer_only.target == "branch" &&
      github_repository_ruleset.mutation_writer_only.rules[0].creation == true &&
      github_repository_ruleset.mutation_writer_only.rules[0].update == true &&
      length(github_repository_ruleset.mutation_writer_only.bypass_actors) == 1 &&
      github_repository_ruleset.mutation_writer_only.bypass_actors[0].actor_type == "Integration" &&
      github_repository_ruleset.mutation_writer_only.bypass_actors[0].actor_id == 4043080 &&
      github_repository_ruleset.mutation_writer_only.bypass_actors[0].bypass_mode == "always" &&
      length(github_repository_ruleset.mutation_writer_only.conditions[0].ref_name[0].exclude) == 0
    )
    error_message = "스위퍼 브랜치는 이름·author만으로 인증하지 않는다. 서버 writer-only 생성·갱신 규칙이 필요하다."
  }
}
