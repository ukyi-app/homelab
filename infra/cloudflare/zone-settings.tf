locals {
  zone_settings = {
    always_use_https         = "on"
    min_tls_version          = "1.2"
    tls_1_3                  = "on"
    opportunistic_encryption = "off"
    automatic_https_rewrites = "on"
    browser_check            = "on"
    security_level           = "medium"
    email_obfuscation        = "on"
  }
}

resource "cloudflare_zone_setting" "baseline" {
  for_each   = local.zone_settings
  zone_id    = local.zone_id
  setting_id = each.key
  value      = each.value
}

resource "cloudflare_zone_setting" "security_header" {
  zone_id    = local.zone_id
  setting_id = "security_header"
  value = {
    strict_transport_security = {
      enabled            = true
      include_subdomains = true
      max_age            = 15552000
      nosniff            = true
      preload            = false
    }
  }
}
