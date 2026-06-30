# Configuration Rules (phase http_config_settings) — 요청 매칭으로 zone 설정을 per-host 오버라이드한다.
#
# page.ukyi.app 한정으로 HTML 변형 엣지 기능(Automatic HTTPS Rewrites + Email Obfuscation + Rocket
# Loader)을 끈다. 이유: 이들 HTML 변형 기능이 켜져 있으면 Cloudflare가 응답의 ETag를 통째로 제거한다
# (검증: 오리진 파드/Traefik 직접 응답엔 강한 ETag가 있으나 공개 page.ukyi.app 응답에선 부재, 본문은
# 바이트 동일; Email Obfuscation off·무압축 요청에서도 제거 → 원인은 변형 기능 자체). page 앱은 리비전
# 단위 강한 ETag(+ Last-Modified)로 조건부 304(미변경 시 본문 전송 생략)를 하므로, 이 호스트에 한해
# 변형 기능을 꺼 검증자가 엣지를 통과하게 한다. zone 전역 기본값은 그대로 유지되어 다른 *.ukyi.app
# 앱에는 영향이 없다. page 페이지들은 CSP default-src 'none' 샌드박스라 mixed-content rewrite·메일
# 난독화가 구조적으로 불필요하다.
#
# 주의: 표현식은 eq만 쓴다 — 정규식 matches는 Business/WAF Advanced 전용이라 무료 플랜에선 apply가
#       400 "not entitled"로 거부된다(cache.tf/waf.tf와 동일 규약).
resource "cloudflare_ruleset" "config_rules" {
  zone_id     = data.cloudflare_zone.this.zone_id
  name        = "homelab-config-rules"
  kind        = "zone"
  phase       = "http_config_settings"
  description = "Per-host edge config: disable HTML-modifying features on page.ukyi.app so the origin ETag survives."
  rules = [
    {
      ref         = "page-preserve-etag"
      description = "page.ukyi.app: disable HTML-modifying features that strip the origin ETag"
      expression  = "(http.host eq \"page.ukyi.app\")"
      action      = "set_config"
      action_parameters = {
        automatic_https_rewrites = false
        email_obfuscation        = false
        rocket_loader            = false
      }
      enabled = true
    }
  ]
}
