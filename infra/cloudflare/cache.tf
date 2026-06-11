resource "cloudflare_ruleset" "cache_rules" {
  zone_id     = data.cloudflare_zone.this.zone_id
  name        = "homelab-cache-rules"
  kind        = "zone"
  phase       = "http_request_cache_settings"
  description = "Cache static assets; bypass API + SSR HTML to avoid per-user leaks."
  rules = [
    {
      ref         = "bypass-api-and-ssr"
      description = "Never cache API or SSR HTML responses"
      expression  = "(http.host eq \"api.${var.zone_name}\") or (http.request.uri.path eq \"/\") or (not http.request.uri.path matches \"^/(assets|_next/static)/\")"
      action      = "set_cache_settings"
      action_parameters = {
        cache = false
      }
      enabled = true
    },
    {
      ref         = "cache-static-assets"
      description = "Edge-cache hashed static assets aggressively"
      expression  = "http.request.uri.path matches \"^/(assets|_next/static)/\""
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
