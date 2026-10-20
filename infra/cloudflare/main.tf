data "cloudflare_zone" "homelab" {
  filter = {
    name = "ukyi.app"
  }
}

locals {
  # 계정 ID를 공개 HCL에 복제하지 않고 유지하는 zone에서 찾는다.
  account_id = data.cloudflare_zone.homelab.account.id
  zone_id    = data.cloudflare_zone.homelab.zone_id
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "homelab" {
  account_id = local.account_id
  name       = "homelab"
  config_src = "cloudflare"
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "homelab" {
  account_id = local.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.homelab.id
  config = {
    # 순서가 의미를 가지므로 리스트로 두고 기본 거절을 반드시 마지막에 둔다.
    ingress = [
      {
        hostname = "*.ukyi.app"
        service  = "http://traefik.traefik.svc.cluster.local:80"
      },
      {
        hostname = "ukyi.app"
        service  = "http://traefik.traefik.svc.cluster.local:80"
      },
      { service = "http_status:404" }
    ]
  }
}

resource "cloudflare_dns_record" "tunnel" {
  for_each = toset(["*.ukyi.app", "ukyi.app"])
  zone_id  = local.zone_id
  name     = each.value
  type     = "CNAME"
  content  = "${cloudflare_zero_trust_tunnel_cloudflared.homelab.id}.cfargotunnel.com"
  proxied  = true
  ttl      = 1
}

resource "cloudflare_ruleset" "webhook" {
  zone_id = local.zone_id
  name    = "homelab-webhook"
  kind    = "zone"
  phase   = "http_request_firewall_custom"
  rules = [{
    ref         = "github_webhook_path_and_method"
    description = "GitHub webhook endpoint"
    action      = "block"
    expression  = "(http.host eq \"hooks.ukyi.app\" and (http.request.uri.path ne \"/github\" or http.request.method ne \"POST\"))"
    enabled     = true
  }]
}

resource "cloudflare_r2_bucket" "backups" {
  account_id = local.account_id
  name       = "homelab-backups"

  lifecycle {
    prevent_destroy = true
  }
}

resource "cloudflare_r2_bucket_lifecycle" "backups" {
  account_id  = local.account_id
  bucket_name = cloudflare_r2_bucket.backups.name
  rules = [{
    id      = "valkey-expire-14d"
    enabled = true
    # 빈 prefix는 PostgreSQL 백업도 지운다. pg/ 보존은 T11의 CNPG가 관리한다.
    conditions = { prefix = "valkey/" }
    delete_objects_transition = {
      condition = { type = "Age", max_age = 1209600 }
    }
  }]
}

data "cloudflare_zero_trust_tunnel_cloudflared_token" "homelab" {
  account_id = local.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.homelab.id
}

output "tunnel_token" {
  description = "Infisical homelab/prod /platform/cloudflared로 사람이 전달한다."
  value       = data.cloudflare_zero_trust_tunnel_cloudflared_token.homelab.token
  sensitive   = true
}
