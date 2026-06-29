locals {
  # 앱 레지스트리 SSOT — create-app/teardown 워크플로가 변이한다. 스키마:
  # [{ "name": "<app>", "host": "<fqdn>", "public": true, "active": true }]
  # create-app PR 머지가 첫 배포 승인 + 공개 승인이다. active=false는 수동 보류/철거 중
  # DNS 회수 상태를 표현할 때만 쓴다.
  apps = jsondecode(file("${path.module}/apps.json"))
  # public && active만 노출: active=false 행은 DNS/tunnel ingress 대상에서 제외된다.
  app_hosts = toset([for a in local.apps : a.host if a.public && a.active])

  tunnel_target = "${cloudflare_zero_trust_tunnel_cloudflared.homelab.id}.cfargotunnel.com"
  # apex/www는 코드 고정(구조적) — destroy 가드가 무인 삭제를 끝까지 차단한다. 앱 host는 apps.json
  # 데이터 합류(자동 관리)라 별도 리소스(cloudflare_dns_record.app)로 분리 — destroy 가드 allowlist
  # (^cloudflare_dns_record\.app\[)가 앱 DNS만 정확히 겨냥하고 apex/www는 보호되게 한다.
  site_hosts = toset([var.zone_name, "www.${var.zone_name}"])
  # tunnel ingress는 apex/www/앱 host 전부를 라우팅한다 — 합집합 유지(tunnel.tf가 참조).
  public_hosts = toset(concat(tolist(local.site_hosts), tolist(local.app_hosts)))
}

# apex/www — 코드 고정 구조적 DNS. destroy 가드가 무인 삭제를 끝까지 차단(allowlist 비대상).
resource "cloudflare_dns_record" "public" {
  for_each = local.site_hosts
  zone_id  = data.cloudflare_zone.this.zone_id
  name     = each.value
  type     = "CNAME"
  content  = local.tunnel_target
  proxied  = true
  ttl      = 1
}

# 앱 공개 host — apps.json 데이터 합류(자동 관리). create-app이 추가·teardown-app이 회수하며,
# destroy 가드 allowlist(^cloudflare_dns_record\.app\[) 대상이라 teardown 머지 시 무인 자동 apply된다.
resource "cloudflare_dns_record" "app" {
  for_each = local.app_hosts
  zone_id  = data.cloudflare_zone.this.zone_id
  name     = each.value
  type     = "CNAME"
  content  = local.tunnel_target
  proxied  = true
  ttl      = 1
}
