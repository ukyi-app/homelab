# R2 access/secret KEY PAIRS are minted as scoped R2 API tokens out-of-band
# (one for pg-backups RW, one for media RW) and injected at Task 2.9.

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
