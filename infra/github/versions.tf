terraform {
  # ⚠️ **정확 핀이다(`>=`가 아니다).** 이 루트는 owner 로컬 apply 전용이고
  # CI(tf-reconcile.yaml의 drift-github 잡)는 plan-only인데, plan도 refresh가 state를 읽으므로
  # CI 바이너리가 state writer보다 낮으면 죽는다. 그 두 변(owner mise · 그 잡)을 한 값에 묶어
  # fail-closed로 만든다.
  # ⚠️ tailscale 루트는 `>= 1.9.0`을 유지한다(drift 잡이 일부러 1.15.5) — 핀은 루트마다 독립이다.
  # renovate: datasource=github-releases depName=hashicorp/terraform
  required_version = "= 1.9.8"
  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.2"
    }
  }
}
