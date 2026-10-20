# GitHub App ID(숫자). App을 만든 뒤 사람이 default에 숫자 리터럴로 적는다(HUMAN-STEPS).
# data.github_app은 fine-grained 토큰에서 404로 죽어 plan을 조용히 무변경으로 만들었다(설계 B.1 P04).
# private App의 ID는 익명 조회가 안 되는 값이라 이 공개 파일에 처음 실린다. 자격은 아니다(키가 있어야 토큰을 발급한다).
# -var·tfvars로 넘기지 않는다(래퍼가 tfvars를 거부한다). 0이면 plan이 여기서 멈춘다.
variable "homelab_deploy_app_id" {
  description = "App homelab-deploy의 ID(ruleset C bypass)"
  type        = number
  default     = 0

  validation {
    condition     = var.homelab_deploy_app_id > 0
    error_message = "homelab_deploy_app_id가 0이다. App homelab-deploy를 만든 뒤 variables.tf의 default에 숫자로 적는다."
  }
}

variable "homelab_merge_app_id" {
  description = "App homelab-merge의 ID(ruleset B bypass)"
  type        = number
  default     = 0

  validation {
    condition     = var.homelab_merge_app_id > 0
    error_message = "homelab_merge_app_id가 0이다. App homelab-merge를 만든 뒤 variables.tf의 default에 숫자로 적는다."
  }
}
