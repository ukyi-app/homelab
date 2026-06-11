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
variable "dns_nameserver_tailscale_ip" {
  type        = string
  description = "전역 nameserver 대상 tailscale IP. 맥미니 tailscale IP(:53이 OrbStack→AdGuard로 포워딩). 전용 LB 디바이스 IP보다 안정적."
}
