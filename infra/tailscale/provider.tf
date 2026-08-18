provider "tailscale" {
  oauth_client_id     = var.ts_bootstrap_oauth_id
  oauth_client_secret = var.ts_bootstrap_oauth_secret
  # 부트스트랩 OAuth 클라이언트에 실제로 부여된 스코프만 요청한다 — "all"을 요청하면
  # 제한 스코프 클라이언트는 토큰 교환 자체가 403("cannot grant scopes all")으로 실패한다.
  # 🔴 2026-08-18: 리터럴이었다. 그래서 CI가 읽기 전용 클라이언트를 받아도 같은 이유로 403이 나
  #    `drift-tailscale`(plan-only 드리프트 감시)이 **원리적으로 열릴 수 없었다.**
  #    기본값은 그대로이므로 owner 로컬 apply의 거동은 불변이다 — 근거는 variables.tf 주석.
  scopes = var.ts_oauth_scopes
}
