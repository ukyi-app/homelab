#!/usr/bin/env bats

# 기본 내부(internal-by-default) 자세 (설계 §6): ArgoCD, Grafana, AdGuard UI는
# 절대 공개적으로 접근 가능하면 안 된다. LoadBalancer는 Traefik 하나뿐이고, 공개
# egress는 cloudflared 하나뿐이다. 공개 접근은 오직 Gateway homelab/gateway의
# 'web-public' 리스너에 붙은 HTTPRoute로만 부여된다 — 이 서비스들은 그것을 가져선 안 된다.
# LIVE: kubectl 컨텍스트 = M3가 sync된 k3s VM 필요.

@test "Traefik is the only LoadBalancer Service in the cluster" {
  run bash -c "kubectl get svc -A -o jsonpath='{range .items[?(@.spec.type==\"LoadBalancer\")]}{.metadata.namespace}/{.metadata.name} {end}'"
  [ "$status" -eq 0 ]
  [ "$output" = "gateway/traefik " ]
}

@test "ArgoCD server has no public HTTPRoute" {
  run bash -c "kubectl get httproute -A -o json | jq -r '.items[] | select(.spec.parentRefs[].sectionName==\"web-public\") | .spec.backendRefs[]?.name' | grep -c '^argocd' || true"
  [ "$output" = "0" ]
}

@test "Grafana has no public HTTPRoute" {
  run bash -c "kubectl get httproute -A -o json | jq -r '.items[] | select(.spec.parentRefs[].sectionName==\"web-public\") | .spec.backendRefs[]?.name' | grep -c '^grafana' || true"
  [ "$output" = "0" ]
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
