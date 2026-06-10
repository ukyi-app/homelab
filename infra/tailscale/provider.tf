provider "tailscale" {
  oauth_client_id     = var.ts_bootstrap_oauth_id
  oauth_client_secret = var.ts_bootstrap_oauth_secret
  # 부트스트랩 OAuth 클라이언트에 실제로 부여된 스코프만 요청한다 — "all"을 요청하면
  # 제한 스코프 클라이언트는 토큰 교환 자체가 403("cannot grant scopes all")으로 실패한다.
  scopes = ["policy_file", "dns", "oauth_keys", "devices:core", "auth_keys"]
}
