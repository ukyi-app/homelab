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
  description = "Apex domain, e.g. example.com (the ukyi.app placeholder)."
}
variable "tunnel_name" {
  type    = string
  default = "homelab-prod"
}
variable "internal_suffix" {
  type        = string
  description = "Internal hostname suffix, e.g. home.example.com."
}
