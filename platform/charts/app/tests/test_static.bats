#!/usr/bin/env bats
CHART="${BATS_TEST_DIRNAME}/.."
dep() { helm template t "$CHART" --set image.repo=ghcr.io/o/x --set image.tag=sha-abc1234 \
  --set resources.requests.cpu=10m --set resources.requests.memory=32Mi \
  --set resources.limits.cpu=100m --set resources.limits.memory=64Mi "$@" | yq 'select(.kind=="Deployment")'; }

@test "static.server rejects caddy (enum is sws-only)" {
  run helm template t "$CHART" --set image.repo=ghcr.io/o/x --set image.tag=sha-abc1234 \
    --set resources.requests.cpu=10m --set resources.requests.memory=32Mi \
    --set resources.limits.cpu=100m --set resources.limits.memory=64Mi \
    --set route.public=true --set route.host=s.example.com --set kind=site --set static.server=caddy
  [ "$status" -ne 0 ]
  # ⚠️ 상한 — 위 단언은 `caddy` 한 값의 rc만 본다. enum에 원소를 더해도(예: nginx 추가) `caddy`는
  #    여전히 red라 완화가 무증인이었다(실측: enum 확장 후 60/60 ok 유지). enum 원소 1은
  #    templates/deployment.yaml:46의 단일 분기와 짝인 계약이라 값 추측 대신 카디널리티로 잰다.
  run jq -e '.properties.static.properties.server.enum|length==1' "$CHART/values.schema.json"
  [ "$status" -eq 0 ]   # 서버 추가 시 deployment.yaml:46 분기와 함께 갱신
}

@test "site probes hit the SWS health endpoint (/health), not legacy split health paths" {
  out=$(dep --set kind=site --set route.public=true --set route.host=s.example.com)
  echo "$out" | grep -q 'path: /health'
  # 이름이 약속하는 「probes」(복수)를 실제로 잰다 — 두 프로브가 같은 /health를 쓰므로 경로 단언
  # 하나로는 한쪽 삭제를 못 잡는다(실측: readiness 블록 삭제해도 전건 초록이었다).
  echo "$out" | grep -qF -- 'livenessProbe:'
  echo "$out" | grep -qF -- 'readinessProbe:'
  run grep -q 'path: /healthz' <<<"$out"; [ "$status" -ne 0 ]
  run grep -q 'path: /readyz' <<<"$out"; [ "$status" -ne 0 ]
}

@test "web probes use one /health endpoint by default" {
  out=$(dep --set kind=web --set route.public=true --set route.host=a.example.com)
  echo "$out" | grep -q 'path: /health'
  run grep -q 'path: /healthz' <<<"$out"; [ "$status" -ne 0 ]
  run grep -q 'path: /readyz' <<<"$out"; [ "$status" -ne 0 ]
}
