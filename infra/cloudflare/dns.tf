locals {
  tunnel_target = "${cloudflare_zero_trust_tunnel_cloudflared.homelab.id}.cfargotunnel.com"
  # 사용자 앱은 외부 레포에서 온보딩하며 필요 시 자기 host를 추가한다. apex/www만 기본 유지.
  public_hosts = toset([var.zone_name, "www.${var.zone_name}"])
}

resource "cloudflare_dns_record" "public" {
  for_each = local.public_hosts
  zone_id  = data.cloudflare_zone.this.zone_id
  name     = each.value
  type     = "CNAME"
  content  = local.tunnel_target
  proxied  = true
  ttl      = 1
}
