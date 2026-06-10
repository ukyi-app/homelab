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

# Ingress rules: public hosts → in-cluster Traefik (plaintext, TLS terminates at edge).
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
        hostname = "api.${var.zone_name}"
        service  = "http://traefik.gateway.svc.cluster.local:80"
      },
      {
        service = "http_status:404"
      }
    ]
  }
}
