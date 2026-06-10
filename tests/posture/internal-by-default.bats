#!/usr/bin/env bats

# Internal-by-default posture (design §6): ArgoCD, Grafana, AdGuard UI must NOT
# be publicly reachable. The ONLY LoadBalancer is Traefik; the ONLY public egress
# is cloudflared. Public reach is granted solely by an HTTPRoute on the
# 'web-public' listener of Gateway homelab/gateway — these services must never have one.
# LIVE: requires kubectl context = k3s VM with M3 synced.

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
