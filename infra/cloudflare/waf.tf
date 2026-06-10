resource "cloudflare_ruleset" "waf_custom" {
  zone_id     = data.cloudflare_zone.this.zone_id
  name        = "homelab-waf-custom"
  kind        = "zone"
  phase       = "http_request_firewall_custom"
  description = "Baseline WAF: block known-bad methods + obvious path traversal."
  rules = [
    {
      ref         = "block-traversal"
      description = "Block path traversal attempts"
      expression  = "(http.request.uri.path contains \"../\") or (http.request.uri.path contains \"..%2f\")"
      action      = "block"
      enabled     = true
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
