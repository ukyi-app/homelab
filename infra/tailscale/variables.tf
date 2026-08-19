variable "ts_bootstrap_oauth_id" {
  type      = string
  sensitive = true
}
variable "ts_bootstrap_oauth_secret" {
  type      = string
  sensitive = true
}
variable "dns_nameserver_tailscale_ip" {
  type = string
  # 정정 2026-08-18: 이전 description은 "맥미니 tailscale IP(:53이 OrbStack→AdGuard로 포워딩)"였다.
  # 컷오버로 대상이 **NUC**(100.109.208.81)로 바뀌었고 OrbStack 포워딩 경로는 소멸했다.
  # ⚠️ `terraform.tfvars.pre-cutover.bak`에는 **맥미니 IP가 남아 있다** — 그 값을 되돌려 넣으면
  #    tailnet 전역 DNS가 죽은 기계를 가리킨다. acl.tf에 폴백이 없어 tailnet 이름해석이 통째로 죽는다.
  description = "tailnet 전역 nameserver로 광고할 tailscale IP. 현재는 NUC(=AdGuard가 :53에 서빙하는 노드). 전용 LB 디바이스 IP보다 안정적이다."
}

# CI의 plan-only 드리프트 감시(`drift-tailscale`)를 열어 주는 유일한 코드 레버다.
# provider가 요청하는 스코프가 하드코딩이면, 읽기 전용 OAuth 클라이언트를 새로 만들어도
# **토큰 교환 자체가 403**("cannot grant scopes …")으로 죽어 CI가 원리적으로 못 돈다
# (policy/workflow-readiness.json의 drift-tailscale owner_action이 이 사실로 2026-08-18 정정됐다).
#
# ⚠️ 기본값은 **owner 로컬 apply가 쓰는 write 집합 그대로**다 — 좁히면 apply가 깨진다.
#    CI는 `TF_VAR_ts_oauth_scopes`로 읽기 전용 집합을 주입한다.
# ✅ **CI용 최소 집합은 실측으로 확정됐다(2026-08-19)** — 추가 실험 불필요:
#      TF_VAR_ts_oauth_scopes='["policy_file:read","dns:read","oauth_keys:read"]'
#    이 값으로 plan이 `No changes`로 통과한다. 셋 다 load-bearing임을 하나씩 빼서 확인했다:
#      · policy_file:read 없음 → `Error: Failed to fetch ACL`
#      · dns:read 없음        → `Error: Error fetching DNS name servers`
#      · oauth_keys:read 없음 → 🔴 **에러가 아니라 허위 드리프트다.** terraform이
#        `tailscale_oauth_client.k8s_operator has been deleted`로 판단해 `Plan: 1 to add`를 낸다.
#        CI를 그 상태로 켜면 30분마다 허위 드리프트가 뜨고, 그걸 보고 apply하면 k8s-operator
#        OAuth 클라이언트가 **중복 생성**된다. 실패보다 나쁜 종류의 통과다.
#    ⚠️ `devices:core`/`auth_keys`는 plan에 불필요하다 — CI 집합에 넣지 마라(권한 과잉).
variable "ts_oauth_scopes" {
  type        = list(string)
  default     = ["policy_file", "dns", "oauth_keys", "devices:core", "auth_keys"]
  description = "provider가 토큰 교환 시 요청할 OAuth 스코프. 기본값 = owner 로컬 apply용 write 집합. CI plan-only는 :read 변종을 주입한다."
}
