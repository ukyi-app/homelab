# R2 access/secret 키 페어는 별도 채널(out-of-band)에서 스코프 지정 R2 API 토큰으로 발급해
# (pg-backups RW용 하나, media RW용 하나) Task 2.9에서 주입한다.

output "tunnel_token" {
  description = "cloudflared run token → seed Secret for the cloudflared Deployment."
  value       = data.cloudflare_zero_trust_tunnel_cloudflared_token.homelab.token
  sensitive   = true
}

output "tunnel_id" {
  value     = cloudflare_zero_trust_tunnel_cloudflared.homelab.id
  sensitive = false
}

output "r2_account_endpoint" {
  value     = "https://${var.cloudflare_account_id}.r2.cloudflarestorage.com"
  sensitive = false
}

output "r2_pg_backups_bucket" {
  value     = cloudflare_r2_bucket.pg_backups.name
  sensitive = false
}

output "r2_media_bucket" {
  value     = cloudflare_r2_bucket.media.name
  sensitive = false
}
