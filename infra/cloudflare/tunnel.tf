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
# set 순회는 순서 비보장 — ingress는 리스트라 sort로 결정적 순서를 강제한다(드리프트 방지).
# 404 catch-all은 항상 마지막.
resource "cloudflare_zero_trust_tunnel_cloudflared_config" "homelab" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.homelab.id
  config = {
    ingress = concat(
      [for h in sort(tolist(local.public_hosts)) : {
        hostname = h
        service  = "http://traefik.gateway.svc.cluster.local:80"
      }],
      [{ service = "http_status:404" }]
    )
  }
}

# v5: run 토큰은 tunnel 리소스의 속성이 아니다 — 이 전용 data source로
# 읽어야 한다 (리소스에는 `token` export가 없음).
data "cloudflare_zero_trust_tunnel_cloudflared_token" "homelab" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.homelab.id
}
