resource "tailscale_acl" "homelab" {
  acl = jsonencode({
    tagOwners = {
      "tag:k8s-operator" = ["autogroup:admin"]
      "tag:k8s"          = ["tag:k8s-operator"]
    }
    acls = [
      # Members reach internal services only through the Traefik ingress proxy
      # (HTTP/HTTPS). kubelet/etcd/NodePort stay closed; kubectl is local via
      # OrbStack, not Tailscale — so no kube-apiserver port is exposed here.
      { action = "accept", src = ["autogroup:member"], dst = ["tag:k8s:80,443"] },
      # The operator only manages the proxy devices it creates (tag:k8s);
      # it does not need tailnet-wide any:any.
      { action = "accept", src = ["tag:k8s-operator"], dst = ["tag:k8s:*"] }
    ]
    # No Funnel: this tailnet is INTERNAL-only (public exposure goes through the
    # Cloudflare Tunnel, never Tailscale Funnel — see internal-by-default, §6).
    # Split-horizon (home.<DOMAIN> → stable Tailscale IP, R7) needs no nodeAttrs.
  })
}

resource "tailscale_dns_split_nameservers" "internal" {
  domain      = var.internal_suffix
  nameservers = [var.tailscale_ip]
}
