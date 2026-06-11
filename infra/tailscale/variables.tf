variable "ts_bootstrap_oauth_id" {
  type      = string
  sensitive = true
}
variable "ts_bootstrap_oauth_secret" {
  type      = string
  sensitive = true
}
variable "internal_suffix" {
  type = string # home.ukyi.app — 전역 nameserver 전환 후 미사용(tfvars 호환 위해 유지)
}
variable "adguard_dns_tailscale_ip" {
  type        = string
  description = "tailscale operator가 adguard-dns-ts LoadBalancer에 발급한 안정적 100.x IP (전역 nameserver 대상)."
}
