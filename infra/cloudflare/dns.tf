locals {
  # 앱 레지스트리 SSOT — create-app/teardown 워크플로가 변이한다. 스키마:
  # [{ "name": "<app>", "host": "<fqdn>", "public": true, "active": true }]
  # create-app PR 머지가 첫 배포 승인 + 공개 승인이다. active=false는 수동 보류/철거 중
  # DNS 회수 상태를 표현할 때만 쓴다.
  apps = jsondecode(file("${path.module}/apps.json"))
  # public && active만 노출: active=false 행은 DNS/tunnel ingress 대상에서 제외된다.
  app_hosts = toset([for a in local.apps : a.host if a.public && a.active])

  tunnel_target = "${cloudflare_zero_trust_tunnel_cloudflared.homelab.id}.cfargotunnel.com"
  # apex/www는 코드 고정 유지, 앱 host는 데이터 합류
  public_hosts = toset(concat([var.zone_name, "www.${var.zone_name}"], tolist(local.app_hosts)))
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
