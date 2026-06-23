resource "cloudflare_ruleset" "waf_custom" {
  zone_id     = data.cloudflare_zone.this.zone_id
  name        = "homelab-waf-custom"
  kind        = "zone"
  phase       = "http_request_firewall_custom"
  description = "Baseline WAF: block known-bad methods + obvious path traversal."
  rules = [
    {
      ref         = "block-traversal"
      description = "Block path traversal attempts (best-effort literals)"
      # ⚠️ 무료 플랜이라 정규식(matches) 불가 → 리터럴 OR만 가능. double-encoding·backslash·점 인코딩
      #    변종까지 보강하나 여전히 best-effort다(완전 커버 불가). 진짜 traversal 방어는 오리진 앱의
      #    path canonicalization(프레임워크 책임) — 이 룰은 엣지 1차 시그널일 뿐이다.
      #    `../`·`..%2f`(단일 인코딩) + `..%5c`(backslash) + `%2e%2e`(점 인코딩) + `..%252f`(double-encode).
      expression = "(http.request.uri.path contains \"../\") or (http.request.uri.path contains \"..%2f\") or (http.request.uri.path contains \"..%5c\") or (http.request.uri.path contains \"%2e%2e\") or (http.request.uri.path contains \"..%252f\")"
      action     = "block"
      enabled    = true
    },
    {
      ref         = "block-disallowed-methods"
      description = "Only allow standard HTTP methods"
      expression  = "not (http.request.method in {\"GET\" \"POST\" \"PUT\" \"PATCH\" \"DELETE\" \"HEAD\" \"OPTIONS\"})"
      action      = "block"
      enabled     = true
    }
  ]
}

# 단일 노드 SPOF L7 보호 — cloudflared→traefik→단일 노드로 흐르는 공개 표면을 IP당 rate-limit로
# brute-force/scrape 플러드에서 보호한다. 무료 플랜 호환 규약(apply에서만 검증되는 entitlement):
#  - 표현식은 단순 연산자만(matches 정규식은 Business 전용 → 400 "not entitled", cache.tf 함정과 동일).
#  - action=block, characteristics에 ip.src + cf.colo.id(필수), 무료는 rate-limit 룰 1개.
#  - period/mitigation_timeout 모두 무료는 10초만 — API가 직접 거부("can only use a period among [10]",
#    "not entitled to use a mitigation timeout different from 10"). 공개 문서의 10/60·60/3600 표기와 달리
#    우리 존 entitlement는 둘 다 10뿐(apply에서만 드러남). 초과 IP를 10초 차단 후 재평가.
#  - period=10s 윈도우에서 100req(=600/min)은 명백한 플러드 임계 — 정상 홈랩 트래픽엔 안 걸린다.
resource "cloudflare_ruleset" "waf_ratelimit" {
  zone_id     = data.cloudflare_zone.this.zone_id
  name        = "homelab-waf-ratelimit"
  kind        = "zone"
  phase       = "http_ratelimit"
  description = "Per-IP L7 rate limit (single-node SPOF protection)."
  rules = [
    {
      ref         = "ip-rate-limit"
      description = "Throttle IPs exceeding 100 req/10s (~600/min)"
      expression  = "true" # 전 요청 대상(matches 미사용 — 무료 플랜)
      action      = "block"
      ratelimit = {
        characteristics     = ["ip.src", "cf.colo.id"]
        period              = 10 # 무료 플랜 유일 허용값
        requests_per_period = 100
        mitigation_timeout  = 10 # 무료는 period와 동일(10초)만 — 초과 IP를 10초 차단 후 재평가
      }
      enabled = true
    }
  ]
}
