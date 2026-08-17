#!/usr/bin/env bats

# Milestone 3 게이트 — 네트워킹 경로 엔드투엔드 검증.
# LIVE: kubectl 컨텍스트 = k3s VM; tailnet에 연결된 기기에서 실행.

setup() {
  # DOMAIN 기본값 — make verify-posture는 KUBECONFIG만 주입하므로 기본 zone(ukyi.app)으로 폴백한다.
  # 다른 zone을 테스트하려면 `DOMAIN=… bats …`로 override(:= 는 미설정일 때만 대입).
  : "${DOMAIN:=ukyi.app}"
}

@test "Gateway 'homelab' is Accepted + Programmed" {
  run bash -c "kubectl -n gateway get gateway homelab -o jsonpath='{range .status.conditions[*]}{.type}={.status};{end}'"
  printf '%s' "$output" | grep -qF -- "Accepted=True"
  [[ "$output" == *"Programmed=True"* ]]
}

@test "GatewayClass traefik is Accepted" {
  run bash -c "kubectl get gatewayclass traefik -o jsonpath='{.status.conditions[?(@.type==\"Accepted\")].status}'"
  [ "$output" = "True" ]
}

@test "whoami HTTPRoute is Accepted + ResolvedRefs" {
  run bash -c "kubectl -n gateway get httproute whoami -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status};{end}'"
  printf '%s' "$output" | grep -qF -- "Accepted=True"
  [[ "$output" == *"ResolvedRefs=True"* ]]
}

@test "cloudflared tunnel deployment is healthy" {
  run bash -c "kubectl -n edge get deploy cloudflared -o jsonpath='{.status.availableReplicas}'"
  [ "$output" = "1" ]
  run bash -c "kubectl -n edge logs deploy/cloudflared --tail=200 | grep -c 'Registered tunnel connection'"
  [ "$output" -ge 1 ]
}

@test "public path serves through Traefik via the tunnel" {
  # whoami는 설계상 내부 전용(web-internal-tls) — 공개 DNS 레코드는 apex/www + platform_hosts + 활성 앱 host다.
  # ⚠️ 인-레포 배포 앱이 **0개**가 되어(page #455 · trip-mate-api 철거) 활성 앱 host가 없다.
  #    공개 경로 증명을 `files`로 옮긴다(reserved-hosts.json의 platform_hosts — dns.tf:18 "베스포크
  #    컴포넌트 다운로드 표면"). 경로는 동일하다: DNS→Cloudflare→tunnel→Traefik web-public→files.
  #    files의 /healthz·/readyz는 **internal 포트** 전용이라 공개 표면이 아니다 → 루트(GET /)로 친다
  #    (라이브 실측 2026-08-12: files.ukyi.app/ = 200 · /health = 404 · page.ukyi.app/health = 000).
  #    앱을 다시 온보딩하면 활성 public 앱 host로 되돌리는 편이 증명력이 높다(앱 경로를 실제로 탄다).
  run bash -c "curl -s -o /dev/null -w '%{http_code}' https://files.${DOMAIN}/"
  [ "$output" = "200" ]
}

@test "tailscale proxy device for Traefik is present in tailnet" {
  # operator 자체 디바이스(homelab-operator)는 least-privilege ACL 탓에 member 디바이스의
  # netmap에 안 보인다 — split-horizon이 실제로 의존하는 것은 Traefik 프록시 디바이스다.
  run bash -c "tailscale status | awk '{print \$2}' | grep -cx homelab"
  [ "$output" -ge 1 ]
}

@test "AdGuard resolves *.home to the stable Tailscale IP" {
  # adguard-dns LB IP(=VM IP)는 Mac에서 직접 라우팅되지 않는다 — 실제 소비 경로는
  # OrbStack 포워딩(dns-forward-trigger 유닛이 트리거, Mac의 localhost/LAN/tailnet IP에
  # 바인드)이다. 이 스위트는 Mac mini(호스트)에서 돌므로 127.0.0.1이 그 경로다.
  #
  # ⚠️ **NUC 이전 후 이 전제는 거짓이 된다.** 베어메탈에는 OrbStack 포워딩도 그 더미 유닛도
  #    없고(host-config 계층이 승계하지 않는다), svclb hostPort가 노드 실주소에 직접 걸린다.
  #    이 파일은 tests/.ci-exclude(posture 그룹)라 게이트가 보지 않으므로 그 순간에도 red가
  #    나지 않는다 — KUBECONFIG를 NUC로 돌린 뒤 `make verify-posture`를 처음 돌릴 때
  #    이 한 건만 실패하고, 메시지는 원인을 전혀 시사하지 않는다. 그때 전송 경로를 노드 IP로
  #    바꿀 것(G4 이후, nuc-port-g2.md B8).
  tsip=$(tailscale ip -4 homelab)
  run bash -c "dig +short +time=3 @127.0.0.1 whoami.home.${DOMAIN}"
  [ "$output" = "$tsip" ]
}
