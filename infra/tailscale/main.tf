resource "tailscale_acl" "homelab" {
  acl = file("${path.module}/policy.hujson")
}
