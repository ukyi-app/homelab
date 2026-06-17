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
