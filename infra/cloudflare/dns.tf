locals {
  tunnel_target = "${cloudflare_zero_trust_tunnel_cloudflared.homelab.id}.cfargotunnel.com"
  public_hosts  = toset([var.zone_name, "www.${var.zone_name}", "api.${var.zone_name}"])
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
