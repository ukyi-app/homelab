resource "cloudflare_ruleset" "cache_rules" {
  zone_id     = data.cloudflare_zone.this.zone_id
  name        = "homelab-cache-rules"
  kind        = "zone"
  phase       = "http_request_cache_settings"
  description = "Cache static assets; bypass API + SSR HTML to avoid per-user leaks."
  # NOTE: 표현식은 starts_with()만 쓴다 — 정규식 matches 연산자는 Cloudflare Business/WAF Advanced
  #       플랜 전용이라 하위 플랜에선 ruleset apply가 400 "not entitled"로 거부된다(tf-reconcile 실패).
  rules = [
    {
      ref         = "bypass-dynamic"
      description = "Never cache SSR HTML / non-static responses (per-user leak 방지)"
      expression  = "(http.request.uri.path eq \"/\") or (not (starts_with(http.request.uri.path, \"/assets/\") or starts_with(http.request.uri.path, \"/_next/static/\")))"
      action      = "set_cache_settings"
      action_parameters = {
        cache = false
      }
      enabled = true
    },
    {
      ref         = "cache-static-assets"
      description = "Edge-cache hashed static assets aggressively"
      expression  = "starts_with(http.request.uri.path, \"/assets/\") or starts_with(http.request.uri.path, \"/_next/static/\")"
      action      = "set_cache_settings"
      action_parameters = {
        cache = true
        edge_ttl = {
          mode    = "override_origin"
          default = 2592000 # 30일 — 에셋은 content-hash가 붙어 있다
        }
        browser_ttl = {
          mode    = "override_origin"
          default = 86400
        }
      }
      enabled = true
    }
  ]
}
