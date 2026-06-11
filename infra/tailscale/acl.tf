resource "tailscale_acl" "homelab" {
  acl = jsonencode({
    tagOwners = {
      "tag:k8s-operator" = ["autogroup:admin"]
      "tag:k8s"          = ["tag:k8s-operator"]
    }
    acls = [
      # 각 멤버는 자기 소유 기기에 대한 전체 접근을 유지한다 (laptop→Mac mini SSH/moshi).
      # 이 줄이 없으면 default-deny ACL이 운영자의 원격 Tailscale SSH 경로를 끊는다.
      { action = "accept", src = ["autogroup:member"], dst = ["autogroup:self:*"] },
      # 멤버는 내부 서비스에 Traefik ingress 프록시(HTTP/HTTPS)를 통해서만 도달한다.
      # 전역 DNS(AdGuard)는 맥미니 tailscale IP:53으로 도달하며, 맥미니는 멤버 자기 소유
      # 기기라 위 autogroup:self:* 규칙이 이미 허용한다 — tag:k8s에 53은 불필요.
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

# 전역 nameserver + Override local DNS: tailscale 켠 모든 기기가 AdGuard를 전체 DNS로 쓴다
# (광고 차단 + *.home.ukyi.app split-horizon 통합). split-nameserver(도메인별)가 아니라
# 전역이라 광고 차단이 모든 쿼리에 적용된다. 폴백 없음(사용자 선택) — AdGuard가 SPOF이며,
# 죽으면 tailscale 기기의 이름해석이 끊긴다(런북 lan-dns 참고).
# nameserver = 맥미니 tailscale IP: 맥미니 :53(OrbStack가 모든 인터페이스에 바인딩) →
# dns-forward-trigger/servicelb DNAT → AdGuard. 전용 tailscale LB 디바이스(Service 재생성
# 시 IP 변동)보다 맥미니 IP가 안정적이라 사용자 선택.
resource "tailscale_dns_nameservers" "global" {
  nameservers = [var.dns_nameserver_tailscale_ip]
}

# 주의: "Override local DNS" 토글은 admin console(DNS 페이지)에서 ON 해야 한다.
# tailscale_dns_configuration(provider alpha)으로 시도하면 매 apply마다 위 nameservers를
# 비우는 race가 발생한다 — 그래서 IaC 밖에 둔다. 한 번 켜면
# tailnet 설정으로 유지된다. 켜야 모든 기기가 AdGuard를 전체 DNS로 써서 광고 차단을 받는다.
