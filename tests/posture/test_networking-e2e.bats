#!/usr/bin/env bats

# 네트워킹 게이트 — 네트워킹 경로 엔드투엔드 검증.
# LIVE: kubectl 컨텍스트 = k3s 노드; tailnet에 연결된 기기에서 실행.

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
  # 플랫폼 경로의 증인은 `files`(reserved-hosts.json의 platform_hosts — dns.tf:18 "베스포크 컴포넌트 다운로드
  # 표면")로 고정한다 — 앱 개수와 무관하게 항상 있다. 경로: DNS→Cloudflare→tunnel→Traefik web-public→files.
  # files의 /healthz·/readyz는 **internal 포트** 전용이라 공개 표면이 아니다 → 루트(GET /)로 친다
  # (라이브 실측 2026-08-12: files.ukyi.app/ = 200 · /health = 404). 활성 앱 host는 아래 @test가 registry에서
  # 파생해 잰다(앱 0개 시절의 손 앵커 page.ukyi.app이 철거 뒤 000으로 죽었던 자리 — 손으로 적지 않는다).
  run bash -c "curl -s -o /dev/null -w '%{http_code}' https://files.${DOMAIN}/"
  [ "$output" = "200" ]
}

@test "active public app hosts from apps.json answer through the tunnel (registry-derived, skip when none)" {
  # 공개 표면의 SSOT는 infra/cloudflare/apps.json(active+public)이다 — host를 손으로 적지 않는다. 0건이면 잴
  # 대상이 없으므로 skip으로 요란하게 표시한다(형제 test_network-policy.bats의 앱 파드 0건 skip과 같은 규율).
  # 어떤 HTTP 응답이든(앱 자신의 404 포함) DNS→Cloudflare→tunnel→Traefik web-public→**앱** 경로를 실제로 탔다는
  # 증거다 — 000(연결 실패)·5xx(경로 중간 실패)만 red. 2026-09-08 실측(page 재온보딩): page.ukyi.app/ = 404(앱 JSON)
  # · /health = 200. 경로 파일은 posture 호스트에서도 있는 tracked JSON이라 KUBECONFIG 없이도 파생된다.
  hosts="$(jq -r '.[] | select(.active == true and .public == true) | .host' "$BATS_TEST_DIRNAME/../../infra/cloudflare/apps.json")"
  [ -n "$hosts" ] || skip "apps.json에 active+public 앱 0건 — 잴 대상이 없다. 온보딩하면 실질 판정으로 복귀한다"
  n=0
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://${h}/")"
    case "$code" in 000|5??) echo "public host ${h}: http=${code}"; return 1;; esac
    n=$((n + 1))
  done <<< "$hosts"
  [ "$n" -ge 1 ]
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
  # LAN 기기에 주는 경로가 정확히 `@<K3S_NODE_IP>`다.
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
