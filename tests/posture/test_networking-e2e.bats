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

@test "the Traefik tailscale proxy device is ONLINE in the tailnet (name derived from the Service, not assumed)" {
  # operator 자체 디바이스(homelab-operator)는 least-privilege ACL 탓에 member 디바이스의
  # netmap에 안 보인다 — split-horizon이 실제로 의존하는 것은 Traefik 프록시 디바이스다.
  # ⚠️ 이름을 가정하지 않는다. 옛 단언 `grep -cx homelab`은 (a) 요청 이름(`tailscale.com/hostname`)이
  #    coordination server의 `-N` 접미로 바뀌면(실제 `homelab-1`) 0건이고, (b) 17일 offline인 Mac 시대
  #    잔존 디바이스 `homelab`을 세어 **시체로 통과**했다(감사 2026-09-02). 실제 machine name의 SSOT는
  #    Service의 status.loadBalancer.ingress[].hostname이고, 온라인 여부는 `tailscale status --json`의
  #    Peer.Online이 준다 — 둘을 묶어야 "프록시가 살아 있다"가 된다.
  run bash -c "kubectl -n gateway get svc traefik-ts -o jsonpath='{.status.loadBalancer.ingress[*].hostname}'"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  name="${output%%.*}"
  run bash -c "tailscale status --json | jq -r --arg n \"$name\" '[.Peer[] | select(.DNSName | startswith(\$n + \".\")) | .Online] | @json'"
  [ "$status" -eq 0 ]
  [ "$output" = "[true]" ]   # 정확히 1대, 온라인 — 0대(미등록)·2대(잔존 디바이스)·offline 전부 red
}

@test "AdGuard resolves *.home to the Traefik proxy's Tailscale IP via the node's hostPort (R7 LAN path)" {
  # 베어메탈 NUC: svclb hostPort 53이 노드 실주소에 직접 걸린다 — R7(라우터 DHCP option 6 → AdGuard)이
  # LAN 기기에 주는 경로가 정확히 `@<K3S_NODE_IP>`다. (예전 Mac mini 시대의 OrbStack 127.0.0.1 포워딩
  # 전제는 2026-08-17 컷오버로 소멸했고, 이 @test는 그 뒤 첫 `make verify-posture`에서 예고대로 red였다.)
  # 기대값은 이름이 아니라 **Service가 보고하는 프록시 IP**다 — `tailscale ip -4 homelab`은 요청 이름이
  # `-N` 접미로 바뀐 순간(또는 잔존 디바이스가 그 이름을 점유한 동안) 엉뚱한 기기를 가리킨다.
  run bash -c "kubectl -n gateway get svc traefik-ts -o jsonpath='{.status.loadBalancer.ingress[*].ip}'"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  tsip="$output"
  node_ip="$("$BATS_TEST_DIRNAME/../../infra/k3s-bootstrap/versions-read.sh" K3S_NODE_IP)"
  [ -n "$node_ip" ]
  run bash -c "dig +short +time=3 @${node_ip} whoami.home.${DOMAIN}"
  [ "$output" = "$tsip" ]
}
