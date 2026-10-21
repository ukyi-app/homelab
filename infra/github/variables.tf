# GitHub App ID(숫자). default에 숫자 리터럴로 둔다. 값은 gh api /apps/<slug> --jq .id(owner ukyi-app)로 읽었다(2026-10-21).
# data.github_app은 fine-grained 토큰에서 404로 죽어 plan을 조용히 무변경으로 만들었다(설계 B.1 P04).
# private App의 ID는 익명 조회가 안 되는 값이라 이 공개 파일에 처음 실린다. 자격은 아니다(키가 있어야 토큰을 발급한다).
# -var·tfvars로 넘기지 않는다(래퍼가 tfvars를 거부한다). 0이면 plan이 여기서 멈춘다.
# 옛 이름 homelab-deploy·homelab-merge는 남의 App이다. bypass에 남의 App이 들지 않게 ukyi-homelab-* 설정 화면의 App ID를 적는다(설계 B.8 E5).
variable "homelab_deploy_app_id" {
  description = "App ukyi-homelab-deploy의 ID(ruleset C bypass)"
  type        = number
  default     = 5404211

  validation {
    condition     = var.homelab_deploy_app_id > 0
    error_message = "homelab_deploy_app_id가 0이다. App ukyi-homelab-deploy를 만든 뒤 variables.tf의 default에 숫자로 적는다."
  }
}

variable "homelab_merge_app_id" {
  description = "App ukyi-homelab-merge의 ID(ruleset B bypass)"
  type        = number
  default     = 5404220

  validation {
    condition     = var.homelab_merge_app_id > 0
    error_message = "homelab_merge_app_id가 0이다. App ukyi-homelab-merge를 만든 뒤 variables.tf의 default에 숫자로 적는다."
  }
}
