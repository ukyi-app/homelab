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
# data "github_app"이 이 slug로 App ID를 해석한다. ⚠️ 이 slug는 실행기 신원과 분리되면 안 된다 — App 리네임은
# 이 변수 + bump-poll.yaml git 신원 + ensure-bump-pr.ts DEFAULT_WRITER를 동시 갱신해야 하며, 아니면 리네임 App
# PR이 untrusted로 분류돼 bump가 fail-closed. 기본값 pin 유지 권장(bats가 default를 신뢰 App에 고정).
variable "writer_app_slug" {
  type    = string
  default = "ukyi-homelab-writer"
}
