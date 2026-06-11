resource "tailscale_acl" "homelab" {
  acl = jsonencode({
    tagOwners = {
      "tag:k8s-operator" = ["autogroup:admin"]
      "tag:k8s"          = ["tag:k8s-operator"]
    }
    acls = [
      # 각 멤버는 자기 소유 기기에 대한 전체 접근을 유지한다 (laptop→Mac mini SSH/moshi).
      # 이 줄이 없으면 default-deny ACL이 운영자의 원격 SSH 경로를 끊는다 — 이 세션이
      # Tailscale SSH 위에서 돌고 있어 라이브 적용 직전에 잡은 함정.
      { action = "accept", src = ["autogroup:member"], dst = ["autogroup:self:*"] },
      # 멤버는 내부 서비스에 Traefik ingress 프록시(HTTP/HTTPS)를 통해서만 도달한다.
      # kubelet/etcd/NodePort는 닫힌 상태 유지; kubectl은 Tailscale이 아니라 OrbStack
      # 경유 로컬이므로 여기서 kube-apiserver 포트는 노출되지 않는다.
      { action = "accept", src = ["autogroup:member"], dst = ["tag:k8s:80,443"] },
      # operator는 자신이 생성한 프록시 기기(tag:k8s)만 관리한다;
      # tailnet 전체 any:any는 필요 없다.
      { action = "accept", src = ["tag:k8s-operator"], dst = ["tag:k8s:*"] }
    ]
    # Tailscale SSH(데몬 가로채기형) 사용 시 ssh 섹션도 필요 — 자기 소유 기기로만 허용.
    ssh = [
      { action = "accept", src = ["autogroup:member"], dst = ["autogroup:self"],
      users = ["autogroup:nonroot", "root"] }
    ]
    # Funnel 없음: 이 tailnet은 내부 전용이다 (public 노출은 Cloudflare Tunnel로만,
    # Tailscale Funnel은 절대 사용하지 않음 — internal-by-default, §6 참고).
    # split-horizon(home.ukyi.app → 고정 Tailscale IP, R7)에는 nodeAttrs가 필요 없다.
  })
}

resource "tailscale_dns_split_nameservers" "internal" {
  domain      = var.internal_suffix
  nameservers = [var.tailscale_ip]
}
