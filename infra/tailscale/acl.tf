resource "tailscale_acl" "homelab" {
  acl = jsonencode({
    tagOwners = {
      "tag:k8s-operator" = ["autogroup:admin"]
      "tag:k8s"          = ["tag:k8s-operator"]
    }
    acls = [
      # 각 멤버는 자기 소유 기기에 대한 전체 접근을 유지한다 (laptop→NUC SSH/moshi).
      # 이 줄이 없으면 default-deny ACL이 운영자의 원격 Tailscale SSH 경로를 끊는다.
      { action = "accept", src = ["autogroup:member"], dst = ["autogroup:self:*"] },
      # 멤버는 내부 서비스에 Traefik ingress 프록시(HTTP/HTTPS)를 통해서만 도달한다.
      # 전역 DNS(AdGuard)는 NUC(=AdGuard가 :53에 서빙하는 노드) tailscale IP:53으로 도달하며,
      # NUC은 owner 소유 기기(autogroup:self)라 위 autogroup:self:* 규칙이 이미 허용한다 —
      # tag:k8s에 53은 불필요.
      # kubelet/etcd/NodePort는 아래 tag:k8s 규칙으로 **열지 않는다**(80,443과 5432만 연다).
      # ⚠️ 그렇다고 apiserver가 닫혀 있다는 뜻은 아니다 — 예전 주석은 "kubectl은 OrbStack 경유
      #    로컬이라 kube-apiserver 포트가 노출되지 않는다"고 적었는데 **거짓이다**. 위
      #    `autogroup:self:*` 한 줄이 owner 소유 기기의 **모든 포트**를 열기 때문이다.
      #    실측(2026-08-12): Mac에서 `curl -k https://100.109.208.81:6443/version` → HTTP 401
      #    (= 인증 전 단계까지 도달). D-i의 Mac 사본 원격 kubectl이 정확히 이 경로를 탄다.
      #    ⇒ tag:k8s에 6443을 **더할 필요가 없다**. 반대로 apiserver를 tailnet에서 막고 싶다면
      #    tag:k8s 규칙이 아니라 저 self 규칙을 좁혀야 한다(그러면 Tailscale SSH도 함께 끊긴다).
      { action = "accept", src = ["autogroup:member"], dst = ["tag:k8s:80,443"] },
      # GUI(TablePlus)+로컬 CLI: CNPG pg(5432)에 tailscale 직결 — **owner(autogroup:admin)만**.
      # ★F2: crown-jewel DB는 autogroup:member 금지(전 tailnet 멤버 노출 방지). autogroup:admin =
      #   tailnet 관리자 = owner. 80,443(웹)은 member 허용이지만 5432(DB 직결)는 admin 전용으로 좁힌다.
      #   (pg-rw-tailscale LB 디바이스는 operator가 tag:k8s로 태그한다.)
      { action = "accept", src = ["autogroup:admin"], dst = ["tag:k8s:5432"] },
      # operator는 자신이 생성한 프록시 기기(tag:k8s)만 관리한다;
      # tailnet 전체 any:any는 필요 없다.
      { action = "accept", src = ["tag:k8s-operator"], dst = ["tag:k8s:*"] }
    ]
    # Tailscale SSH(데몬 가로채기형) 사용 시 ssh 섹션도 필요 — 자기 소유 기기로만 허용.
    # ⚠️ users에 `root`가 있어 `ssh root@<기기>`가 **패스워드 없이** 된다(실측 2026-08-12:
    #    `ssh root@100.109.208.81 'id'` → uid=0). D-i는 이것을 verify-cluster [5]의 비대화형
    #    에스케이프로 쓴다(`K3S_RUN="ssh root@…"`) — NOPASSWD sudoers 드롭인이 **불필요한 이유**다.
    #    이 줄을 좁히면 그 경로가 사라지므로 D-i 결정을 함께 재검토할 것.
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
# nameserver = NUC tailscale IP: AdGuard가 :53에 서빙하는 노드 → servicelb DNAT → AdGuard.
# 전용 tailscale LB 디바이스(Service 재생성 시 IP 변동)보다 노드 IP가 안정적이라 사용자 선택.
# 옛 "맥미니 :53(OrbStack가 모든 인터페이스에 바인딩)" 경로는 2026-08-18 컷오버로 **소멸했다**
# (근거 전문은 variables.tf `dns_nameserver_tailscale_ip`).
# ⚠️ 이 값은 gitignored `terraform.tfvars`에 있어 diff에 보이지 않는다. `terraform.tfvars.pre-cutover.bak`
#    의 맥미니 IP를 되돌려 넣으면 tailnet 전역 DNS가 죽은 기계를 가리키고, AdGuard/클러스터가
#    내려간 순간 tailscale을 켠 **모든 기기**의 이름해석이 죽는데 `terraform apply`는 성공한다
#    (가드 0건). `.bak` 복원 금지.
# ⚠️ 그리고 **k3s 노드 자신은 이 전역 nameserver를 받으면 안 된다.** `~.` 라우팅 도메인이 노드의
#    모든 질의를 MagicDNS로 끌어가 이름해석이 클러스터를 경유하게 되고, 그게 §2.4 콜드스타트
#    교착이다. 노드에서는 `tailscale set --accept-dns=false`로 끊는다
#    (`infra/k3s-bootstrap/host-config.sh --apply`가 걸고, `host-preflight.sh` [3]이 검사한다).
resource "tailscale_dns_nameservers" "global" {
  nameservers = [var.dns_nameserver_tailscale_ip]
}

# 주의: "Override local DNS" 토글은 admin console(DNS 페이지)에서 ON 해야 한다.
# tailscale_dns_configuration(provider alpha)으로 시도하면 매 apply마다 위 nameservers를
# 비우는 race가 발생한다 — 그래서 IaC 밖에 둔다. 한 번 켜면
# tailnet 설정으로 유지된다. 켜야 모든 기기가 AdGuard를 전체 DNS로 써서 광고 차단을 받는다.
