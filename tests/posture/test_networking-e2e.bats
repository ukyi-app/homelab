#!/usr/bin/env bats

# Milestone 3 게이트 — 네트워킹 경로 엔드투엔드 검증.
# LIVE: DOMAIN env 설정 필요; kubectl 컨텍스트 = k3s VM; tailnet에 연결된 기기에서 실행.

@test "Gateway 'homelab' is Accepted + Programmed" {
  run bash -c "kubectl -n gateway get gateway homelab -o jsonpath='{range .status.conditions[*]}{.type}={.status};{end}'"
  [[ "$output" == *"Accepted=True"* ]]
  [[ "$output" == *"Programmed=True"* ]]
}

@test "GatewayClass traefik is Accepted" {
  run bash -c "kubectl get gatewayclass traefik -o jsonpath='{.status.conditions[?(@.type==\"Accepted\")].status}'"
  [ "$output" = "True" ]
}

@test "whoami HTTPRoute is Accepted + ResolvedRefs" {
  run bash -c "kubectl -n gateway get httproute whoami -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status};{end}'"
  [[ "$output" == *"Accepted=True"* ]]
  [[ "$output" == *"ResolvedRefs=True"* ]]
}

@test "cloudflared tunnel deployment is healthy" {
  run bash -c "kubectl -n edge get deploy cloudflared -o jsonpath='{.status.availableReplicas}'"
  [ "$output" = "1" ]
  run bash -c "kubectl -n edge logs deploy/cloudflared --tail=200 | grep -c 'Registered tunnel connection'"
  [ "$output" -ge 1 ]
}

@test "public path serves through Traefik via the tunnel" {
  # whoami는 설계상 내부 전용(web-internal) — 공개 DNS 레코드는 apex/api/www뿐이다.
  # 공개 경로 증명은 api 앱의 /health로 한다 (DNS→Cloudflare→tunnel→Traefik web-public→api).
  run bash -c "curl -s -o /dev/null -w '%{http_code}' https://api.${DOMAIN}/health"
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
  tsip=$(tailscale ip -4 homelab)
  run bash -c "dig +short +time=3 @127.0.0.1 whoami.home.${DOMAIN}"
  [ "$output" = "$tsip" ]
}
