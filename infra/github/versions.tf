terraform {
  # owner 로컬과 CI 실행 버전을 정확 핀으로 맞춘다.
  # 새 state 형식의 하위 버전 호환은 보장되지 않으므로 두 실행 환경을 함께 갱신한다.
  # tailscale은 >= 1.9.0 계약을 유지하며 plan-only CI 핀은 별도로 검토한다.
  # renovate: datasource=github-releases depName=hashicorp/terraform
  required_version = "= 1.16.2"
  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.2"
    }
  }
}
