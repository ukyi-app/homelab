resource "tailscale_acl" "homelab" {
  acl = jsonencode({
    tagOwners = {
      "tag:k8s-operator" = ["autogroup:admin"]
      "tag:k8s"          = ["tag:k8s-operator"]
    }
    acls = [
      # Each member keeps FULL access to their OWN devices (laptop→Mac mini SSH/moshi).
      # 이 줄이 없으면 default-deny ACL이 운영자의 원격 SSH 경로를 끊는다 — 이 세션이
      # Tailscale SSH 위에서 돌고 있어 라이브 적용 직전에 잡은 함정.
      { action = "accept", src = ["autogroup:member"], dst = ["autogroup:self:*"] },
      # Members reach internal services only through the Traefik ingress proxy
      # (HTTP/HTTPS). kubelet/etcd/NodePort stay closed; kubectl is local via
      # OrbStack, not Tailscale — so no kube-apiserver port is exposed here.
      { action = "accept", src = ["autogroup:member"], dst = ["tag:k8s:80,443"] },
      # The operator only manages the proxy devices it creates (tag:k8s);
      # it does not need tailnet-wide any:any.
      { action = "accept", src = ["tag:k8s-operator"], dst = ["tag:k8s:*"] }
    ]
    # Tailscale SSH(데몬 가로채기형) 사용 시 ssh 섹션도 필요 — 자기 소유 기기로만 허용.
    ssh = [
      { action = "accept", src = ["autogroup:member"], dst = ["autogroup:self"],
      users = ["autogroup:nonroot", "root"] }
    ]
    # No Funnel: this tailnet is INTERNAL-only (public exposure goes through the
    # Cloudflare Tunnel, never Tailscale Funnel — see internal-by-default, §6).
    # Split-horizon (home.ukyi.app → stable Tailscale IP, R7) needs no nodeAttrs.
  })
}

resource "tailscale_dns_split_nameservers" "internal" {
  domain      = var.internal_suffix
  nameservers = [var.tailscale_ip]
}
