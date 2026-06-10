variable "cloudflare_api_token" {
  type        = string
  sensitive   = true
  description = "Cloudflare API token (Zone:Edit, DNS:Edit, Workers R2:Edit, Cloudflare Tunnel:Edit)."
}
variable "cloudflare_account_id" {
  type        = string
  description = "Cloudflare account ID."
}
variable "zone_name" {
  type        = string
  description = "Apex domain, e.g. example.com (the <DOMAIN> placeholder)."
}
variable "tunnel_name" {
  type    = string
  default = "homelab-prod"
}
variable "internal_suffix" {
  type        = string
  description = "Internal hostname suffix, e.g. int.example.com."
}
variable "tailscale_ip" {
  type        = string
  description = "Stable Tailscale IP of the VM (for split-horizon; used by AdGuard/Tailscale roots, surfaced here for record)."
  default     = ""
}
