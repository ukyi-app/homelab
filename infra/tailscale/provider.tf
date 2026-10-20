provider "tailscale" {
  # 기본 all 요청은 제한된 OAuth client에서 거절된다. tailnet은 자격의 소유자로 추론한다.
  # policy_file 쓰기는 devices:posture_attributes와 devices:core:read가 함께 있어야 한다(Tailscale trust credentials 문서).
  scopes = ["policy_file", "devices:posture_attributes", "devices:core:read"]
}
