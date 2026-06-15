#!/usr/bin/env bats
CHART="${BATS_TEST_DIRNAME}/.."
R="--set resources.requests.cpu=50m --set resources.requests.memory=64Mi \
   --set resources.limits.cpu=500m --set resources.limits.memory=128Mi"

dep() { helm template t "$CHART" --set image.repo=ghcr.io/o/x --set image.tag=sha-abc1234 $R "$@" | yq 'select(.kind=="Deployment")'; }

@test "api Deployment is wave2, non-root, with probes and scrape annotation" {
  out=$(dep --set kind=api --set route.host=api.example.com)
  [[ "$out" == *'argocd.argoproj.io/sync-wave: "2"'* ]]
  [[ "$out" == *"runAsNonRoot: true"* ]]
  [[ "$out" == *"runAsUser: 65532"* ]]
  [[ "$out" == *"path: /healthz"* ]]
  [[ "$out" == *"path: /readyz"* ]]
  [[ "$out" == *'prometheus.io/scrape: "true"'* ]]
  [[ "$out" == *"sleep"* ]]
  [[ "$out" == *"terminationGracePeriodSeconds: 30"* ]]
}

@test "worker Deployment has no readiness HTTP probe (no route)" {
  out=$(dep --set kind=worker)
  [[ "$out" != *"httpGet"* ]]
}

@test "Deployment renders the restricted-compliant security context (hardening SSOT regression guard)" {
  # 모든 앱의 보안 SSOT(values.yaml podSecurityContext/securityContext)가 약화되면 prod
  # PSA restricted enforce가 첫 앱부터 거부한다 — 그 회귀를 차트 단계에서 잡는다.
  # grep(단순 명령)으로 단언: bash 3.2에서도 중간 단언이 게이트된다([[ ]] 함정 회피).
  out=$(dep --set kind=api --set route.host=api.example.com)
  echo "$out" | grep -q 'seccompProfile'
  echo "$out" | grep -q 'type: RuntimeDefault'
  echo "$out" | grep -q 'allowPrivilegeEscalation: false'
  echo "$out" | grep -q 'readOnlyRootFilesystem: true'
  echo "$out" | grep -q 'drop:'
  echo "$out" | grep -q -- '- ALL'
}

@test "spa Deployment runs static-web-server (SWS args) when spa.server=sws" {
  out=$(dep --set kind=spa --set route.host=app.example.com --set spa.server=sws)
  # SWS 서빙 여부는 args(--page-fallback + --root /public)로 검증 — 주석 내용과 무관.
  [[ "$out" == *"--page-fallback"* ]]
  [[ "$out" == *"/public"* ]]
  [[ "$out" == *"readOnlyRootFilesystem: true"* ]]
}
