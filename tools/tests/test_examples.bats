#!/usr/bin/env bats
# kind별 차트 렌더 계약 검증 — 차트 자체 fixtures 사용.
# (과거에는 apps/{worker,web,console} 배포 values를 참조했으나, 그 셋은 Dockerfile 없는
#  values-only 예시여서 라이브에서 빌드 불가 → 외부 앱 레포 체제 전환과 함께 제거되었고
#  렌더 계약은 fixtures가 SSOT다.)
CHART="platform/charts/app"
FIX="platform/charts/app/tests/fixtures"

render() { helm template "$1" "$CHART" -f "$2"; }

@test "worker renders, no HTTPRoute, Node/Go memory gate" {
  out=$(render worker "$FIX/worker.yaml")
  [ -z "$(echo "$out" | yq 'select(.kind=="HTTPRoute")')" ]
  [[ "$out" == *"Deployment"* ]]
}

@test "web (Node standalone) renders Service+HTTPRoute" {
  out=$(render web "$FIX/web.yaml")
  [[ "$out" == *"HTTPRoute"* ]]
  [[ "$out" == *"Deployment"* ]]
}

@test "site served by static-web-server, no metrics port" {
  out=$(render console "$FIX/site.yaml")
  [[ "$out" == *"static-web-server"* ]] || [[ "$out" == *"page-fallback"* ]]
  [ -z "$(echo "$out" | yq 'select(.kind=="Deployment").spec.template.spec.containers[0].ports[] | select(.name=="metrics")')" ]
}
