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
  # 플랫폼 공개 host — 코드 고정(구조적), 앱이 아님. reserved-hosts.json이 SSOT(dns.tf·create-app·
  # test_apps_structure·dns-drift 4소비자 공유). apps.json(앱 레지스트리, 데이터 합류·자동 회수)과
  # 분리한다 — 예약 host는 자동 회수 대상이 아니라 destroy 가드 allowlist(^cloudflare_dns_record\.app\[)
  # 비대상이라 apex/www처럼 무인 삭제로부터 보호된다.
  # argocd-webhook: ArgoCD /api/webhook만 공개(UI는 내부 전용). files: 베스포크 컴포넌트 다운로드 표면.
  site_hosts     = toset([var.zone_name, "www.${var.zone_name}"])
  platform_hosts = toset(jsondecode(file("${path.module}/reserved-hosts.json")).platform_hosts)
  # tunnel ingress는 apex/www/플랫폼/앱 host 전부를 라우팅한다 — 합집합 유지(tunnel.tf가 참조).
  public_hosts = toset(concat(tolist(local.site_hosts), tolist(local.platform_hosts), tolist(local.app_hosts)))
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

# 플랫폼 공개 host(argocd-webhook 등) — 코드 고정 구조적 DNS. apex/www와 동일하게 destroy 가드
# allowlist(^cloudflare_dns_record\.app\[) 비대상이라 무인 삭제로부터 보호된다.
resource "cloudflare_dns_record" "platform" {
  for_each = local.platform_hosts
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
