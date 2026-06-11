resource "random_password" "tunnel_secret" {
  length  = 64
  special = false
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "homelab" {
  account_id    = var.cloudflare_account_id
  name          = var.tunnel_name
  tunnel_secret = base64encode(random_password.tunnel_secret.result)
  config_src    = "cloudflare"
}

# Ingress 규칙: public 호스트 → 클러스터 내부 Traefik (plaintext, TLS는 edge에서 종료).
resource "cloudflare_zero_trust_tunnel_cloudflared_config" "homelab" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.homelab.id
  config = {
    ingress = [
      {
        hostname = var.zone_name
        service  = "http://traefik.gateway.svc.cluster.local:80"
      },
      {
        hostname = "www.${var.zone_name}"
        service  = "http://traefik.gateway.svc.cluster.local:80"
      },
      {
        service = "http_status:404"
      }
    ]
  }
}

# v5: run 토큰은 tunnel 리소스의 속성이 아니다 — 이 전용 data source로
# 읽어야 한다 (리소스에는 `token` export가 없음).
data "cloudflare_zero_trust_tunnel_cloudflared_token" "homelab" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.homelab.id
}
