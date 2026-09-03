terraform {
  # ⚠️ **정확 핀이다(`>=`가 아니다).** 이 루트의 state는 CI(iac.yaml apply·tf-reconcile apply)와
  # owner 로컬 apply(blocked-delete 복구 경로)가 번갈아 쓴다 — terraform은 state를 쓴 버전보다
  # 낮은 바이너리로 그 state를 **읽지도 못하므로**, 그 writer 집합이 한 값이어야 한다.
  # 등식의 변: iac.yaml의 iac-plan·apply 잡 · tf-reconcile.yaml의 reconcile 잡 · owner mise 바이너리.
  # (iac.yaml의 iac-validate 잡은 `init -backend=false`라 state를 안 만지지만 같은 값이라 함께 통과한다.)
  # 한 변만 올라가면 init 단계에서 fail-closed로 죽는다 — 갈린 채 state를 쓰는 것보다 낫다.
  # ⚠️ tailscale 루트는 `>= 1.9.0`을 유지한다. 거기는 drift 잡이 일부러 1.15.5로 돈다
  #    (docs/traps-detail.md 「owner 로컬 apply 루트는 …」) — 핀 통일이 오히려 고장인 자리다.
  # renovate: datasource=github-releases depName=hashicorp/terraform
  required_version = "= 1.9.8"
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
