resource "tailscale_acl" "homelab" {
  acl = jsonencode({
    tagOwners = {
      "tag:k8s-operator" = ["autogroup:admin"]
      "tag:k8s"          = ["tag:k8s-operator"]
    }
    acls = [
      { action = "accept", src = ["autogroup:member"], dst = ["tag:k8s:*"] },
      { action = "accept", src = ["tag:k8s-operator"], dst = ["*:*"] }
    ]
    # Split-horizon: int.<DOMAIN> resolves to the in-VM Traefik via the
    # operator-exposed Ingress, pinned to the stable Tailscale IP (R7).
    nodeAttrs = [
      { target = ["tag:k8s"], attr = ["funnel"] }
    ]
  })
}

resource "tailscale_dns_split_nameservers" "internal" {
  domain      = var.internal_suffix
  nameservers = [var.tailscale_ip]
}
