#!/usr/bin/env bats

# 기본 내부(internal-by-default) 자세 (설계 §6): ArgoCD, Grafana, AdGuard UI는
# 절대 공개적으로 접근 가능하면 안 된다. LoadBalancer는 Traefik 하나뿐이고, 공개
# egress는 cloudflared 하나뿐이다. 공개 접근은 오직 Gateway homelab/gateway의
# 'web-public' 리스너에 붙은 HTTPRoute로만 부여된다 — 이 서비스들은 그것을 가져선 안 된다.
# LIVE: kubectl 컨텍스트 = M3가 sync된 k3s VM 필요.

@test "servicelb LoadBalancer Services are exactly traefik + adguard-dns" {
  # adguard-dns LB는 R7 설계상 필수(LAN DHCP option 6 대상 — lan-dns 런북): servicelb가
  # VM 노드 IP에 :53을 게시한다. 그 외 servicelb LoadBalancer가 늘어나면 공개면 확장이므로 실패해야 한다.
  # ⚠️ tailscale operator가 만든 LB(loadBalancerClass=tailscale, pg-rw-tailscale·traefik-ts)는
  # tailnet 전용(공개면 아님)이라 제외한다 — servicelb(class 미지정) LB만 공개면 후보다.
  run bash -c "kubectl get svc -A -o json | jq -r '[.items[] | select(.spec.type==\"LoadBalancer\") | select((.spec.loadBalancerClass // \"\") != \"tailscale\") | \"\(.metadata.namespace)/\(.metadata.name)\"] | sort | join(\" \")'"
  [ "$status" -eq 0 ]
  [ "$output" = "edge/adguard-dns gateway/traefik" ]
}

@test "ArgoCD server is public only via the /api/webhook allowlist" {
  # HTTPRoute backendRefs는 .spec.rules[].backendRefs에 있다(.spec.backendRefs는 부재 — 옛 vacuous 버그).
  # web-public 리스너의 argocd-* 백엔드는 오직 argocd-webhook 라우트의 /api/webhook prefix만 허용한다.
  # matches 생략 시 Gateway API 기본값은 PathPrefix '/'(전면 노출)이므로 위반으로 센다.
  run kubectl get httproute -A -o json
  [ "$status" -eq 0 ]
  count="$(jq '[
      .items[]
      | select(any(.spec.parentRefs[]?; .sectionName=="web-public"))
      | .spec.rules[]?
      | select(any(.backendRefs[]?; (.name // "") | startswith("argocd")))
      | (if (.matches // [] | length)==0 then ["/"] else (.matches | map(.path.value // "/")) end) as $paths
      | select(any($paths[]; . != "/api/webhook"))
    ] | length' <<<"$output")"
  [ "$count" = "0" ]   # /api/webhook 이외 경로로 argocd를 web-public에 노출하는 rule 0
}

@test "Grafana has no public HTTPRoute" {
  run kubectl get httproute -A -o json
  [ "$status" -eq 0 ]
  count="$(jq '[
      .items[]
      | select(any(.spec.parentRefs[]?; .sectionName=="web-public"))
      | .spec.rules[]?
      | select(any(.backendRefs[]?; (.name // "") | startswith("grafana")))
    ] | length' <<<"$output")"
  [ "$count" = "0" ]   # grafana 백엔드는 web-public 리스너에 절대 없어야 한다(내부 전용)
}

@test "AdGuard UI is ClusterIP (Tailscale-only), never LoadBalancer" {
  run bash -c "kubectl -n edge get svc adguard-ui -o jsonpath='{.spec.type}'"
  [ "$output" = "ClusterIP" ]
}

@test "cloudflared ingress targets only Traefik (no direct app/admin services)" {
  run bash -c "kubectl -n edge get cm cloudflared -o jsonpath='{.data.config\.yaml}' | grep -c 'traefik.gateway.svc.cluster.local'"
  [ "$output" -ge 1 ]
  run bash -c "kubectl -n edge get cm cloudflared -o jsonpath='{.data.config\.yaml}' | grep -Ec 'argocd|grafana|adguard'"
  [ "$output" = "0" ]
}
