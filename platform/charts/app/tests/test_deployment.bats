#!/usr/bin/env bats
CHART="${BATS_TEST_DIRNAME}/.."
R="--set resources.requests.cpu=50m --set resources.requests.memory=64Mi \
   --set resources.limits.cpu=500m --set resources.limits.memory=128Mi"

dep() { helm template t "$CHART" --set image.repo=ghcr.io/o/x --set image.tag=sha-abc1234 $R "$@" | yq 'select(.kind=="Deployment")'; }

@test "web Deployment is wave2, non-root, with one health probe endpoint" {
  out=$(dep --set kind=web --set route.public=true --set route.host=api.example.com)
  echo "$out" | grep -qF 'argocd.argoproj.io/sync-wave: "2"'
  echo "$out" | grep -qF 'runAsNonRoot: true'
  echo "$out" | grep -qF 'runAsUser: 65532'
  echo "$out" | grep -qF 'path: /health'
  run grep -qF 'path: /healthz' <<<"$out"; [ "$status" -ne 0 ]
  run grep -qF 'path: /readyz' <<<"$out"; [ "$status" -ne 0 ]
  run grep -qF 'sleep' <<<"$out"; [ "$status" -ne 0 ]
  echo "$out" | grep -qF 'terminationGracePeriodSeconds: 30'
}

@test "worker Deployment has no readiness HTTP probe (no route)" {
  out=$(dep --set kind=worker)
  [[ "$out" != *"httpGet"* ]]
}

@test "Deployment renders the restricted-compliant security context (hardening SSOT regression guard)" {
  # 모든 앱의 보안 SSOT(values.yaml podSecurityContext/securityContext)가 약화되면 prod
  # PSA restricted enforce가 첫 앱부터 거부한다 — 그 회귀를 차트 단계에서 잡는다.
  # grep(단순 명령)으로 단언: bash 3.2에서도 중간 단언이 게이트된다([[ ]] 함정 회피).
  out=$(dep --set kind=web --set route.public=true --set route.host=api.example.com)
  echo "$out" | grep -q 'seccompProfile'
  echo "$out" | grep -q 'type: RuntimeDefault'
  echo "$out" | grep -q 'allowPrivilegeEscalation: false'
  echo "$out" | grep -q 'readOnlyRootFilesystem: true'
  echo "$out" | grep -q 'drop:'
  echo "$out" | grep -q -- '- ALL'
}

@test "static Deployment runs static-web-server (SWS args) when static.server=sws" {
  out=$(dep --set kind=site --set route.public=true --set route.host=app.example.com --set static.server=sws)
  # SWS 서빙 여부는 args(--page-fallback + --root /public)로 검증 — 주석 내용과 무관.
  echo "$out" | grep -qF -- '--page-fallback'
  echo "$out" | grep -qF '/public'
  echo "$out" | grep -qF 'readOnlyRootFilesystem: true'
}

@test "Deployment defaults imagePullSecrets to ghcr-pull (private GHCR pull, no public toggle)" {
  out=$(dep --set kind=web --set route.public=true --set route.host=api.example.com)
  echo "$out" | grep -q 'imagePullSecrets:'
  echo "$out" | grep -q 'name: ghcr-pull'
}
