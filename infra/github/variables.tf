variable "github_owner" {
  type = string
}
variable "github_token" {
  type      = string
  sensitive = true
}
variable "repo_name" {
  type    = string
  default = "homelab"
}
variable "telegram_bot_token" {
  type      = string
  sensitive = true
}
variable "telegram_chat_id" {
  type      = string
  sensitive = true
}

# (writer_app_slug 변수는 제거됨 — bump-poll ruleset이 App ID(4043080)를 직접 핀한다. rulesets.tf 주석 참고:
#  fine-grained PAT가 GET /apps/{slug}를 404로 막아 slug data source가 못 쓰인다. 리네임 시 실행기 신원
#  2곳(run-bump-plan.ts WRITER_NAME · ensure-bump-pr DEFAULT_WRITER)은 그대로 App 이름을 쓰고, 룰셋은
#  ID로 고정돼 리네임에 영향받지 않는다.)
