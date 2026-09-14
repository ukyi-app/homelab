# 기존 repository secret은 먼저 state 관리만 해제한다(원격 삭제 없음).
# 환경 복제·workflow 배선·canary 검증 뒤 owner가 원본 공급을 명시적으로 회수한다.
# removed 블록을 지워도 이전 repository secret 선언을 복원하지 않는다.
removed {
  from = github_actions_secret.telegram_bot_token
  lifecycle {
    destroy = false
  }
}
removed {
  from = github_actions_secret.telegram_chat_id
  lifecycle {
    destroy = false
  }
}

resource "github_actions_environment_secret" "telegram_bot_token" {
  repository  = data.github_repository.homelab.name
  environment = github_repository_environment.main.environment
  secret_name = "TELEGRAM_BOT_TOKEN"
  value       = var.telegram_bot_token
  depends_on  = [github_repository_environment_deployment_policy.main]
}
resource "github_actions_environment_secret" "telegram_chat_id" {
  repository  = data.github_repository.homelab.name
  environment = github_repository_environment.main.environment
  secret_name = "TELEGRAM_CHAT_ID"
  value       = var.telegram_chat_id
  depends_on  = [github_repository_environment_deployment_policy.main]
}
