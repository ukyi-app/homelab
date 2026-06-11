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
  run bash -c "curl -s -o /dev/null -w '%{http_code}' https://whoami.${DOMAIN}/"
  [ "$output" = "200" ]
}

@test "tailscale operator node is present in tailnet" {
  run bash -c "tailscale status | grep -c 'homelab-operator'"
  [ "$output" -ge 1 ]
}

@test "AdGuard resolves *.int to the stable Tailscale IP" {
  ag=$(kubectl -n edge get svc adguard-dns -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  tsip=$(tailscale ip -4 homelab)
  run bash -c "dig +short @${ag} whoami.int.${DOMAIN}"
  [ "$output" = "$tsip" ]
}
