provider "tailscale" {
  # 기본 all 요청은 제한된 OAuth client에서 거절된다. tailnet은 자격의 소유자로 추론한다.
  scopes = ["policy_file"]
}
