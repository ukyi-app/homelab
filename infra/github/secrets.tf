resource "github_actions_secret" "bot_pat" {
  repository      = github_repository.homelab.name
  secret_name     = "DEPLOY_BOT_PAT"
  plaintext_value = var.bot_pat
}
resource "github_actions_secret" "telegram_bot_token" {
  repository      = github_repository.homelab.name
  secret_name     = "TELEGRAM_BOT_TOKEN"
  plaintext_value = var.telegram_bot_token
}
resource "github_actions_secret" "telegram_chat_id" {
  repository      = github_repository.homelab.name
  secret_name     = "TELEGRAM_CHAT_ID"
  plaintext_value = var.telegram_chat_id
}
