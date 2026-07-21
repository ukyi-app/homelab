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

# bump-poll/** 예약 ruleset의 bypass actor로 쓸 writer App slug. 시크릿 아님(App slug는 공개 식별자) —
# data "github_app"이 이 slug로 App ID를 해석한다. 기본값 유지 권장(App 리네임 시에만 override).
variable "writer_app_slug" {
  type    = string
  default = "ukyi-homelab-writer"
}
