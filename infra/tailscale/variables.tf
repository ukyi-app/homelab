variable "ts_bootstrap_oauth_id" {
  type      = string
  sensitive = true
}
variable "ts_bootstrap_oauth_secret" {
  type      = string
  sensitive = true
}
variable "internal_suffix" {
  type = string # home.<DOMAIN>
}
variable "tailscale_ip" {
  type        = string
  description = "Stable Tailscale IP of the VM (split-DNS nameserver target)."
}
