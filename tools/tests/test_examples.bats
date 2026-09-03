#!/usr/bin/env bats
# kind별 차트 렌더 계약 검증 — 차트 자체 fixtures 사용.
# (과거에는 apps/{worker,web,console} 배포 values를 참조했으나, 그 셋은 Dockerfile 없는
#  values-only 예시여서 라이브에서 빌드 불가 → 외부 앱 레포 체제 전환과 함께 제거되었고
#  렌더 계약은 fixtures가 SSOT다.)
# ⚠️ 메모리는 이 파일 소관이 아니다 — 앱 사이징은 platform/charts/app/values.schema.json이
#    resources 4값(requests/limits × cpu/memory)을 required로 강제하고, 그 증인은
#    platform/charts/app/tests/test_schema.bats:20·39(「per-app sizing gate」·「sizing-discipline」)다.
#    platform 상주 워크로드 쪽은 docs/memory-ledger.md 원장 + tools/check-resource-limits.ts
#    (GOMEMLIMIT ≤ limit×0.95). 차트 templates/에는 GOMEMLIMIT/NODE_OPTIONS 주입 자리가 없다(실측 0건)
#    — 그래서 @test 이름도 그것을 약속하지 않는다.
CHART="platform/charts/app"
FIX="platform/charts/app/tests/fixtures"

render() { helm template "$1" "$CHART" -f "$2"; }

@test "worker renders a Deployment and no HTTPRoute" {
  out=$(render worker "$FIX/worker.yaml")
  [ -z "$(echo "$out" | yq 'select(.kind=="HTTPRoute")')" ]
  [[ "$out" == *"Deployment"* ]]
}

@test "web (Node standalone) renders an HTTPRoute" {
  out=$(render web "$FIX/web.yaml")
  printf '%s' "$out" | grep -qF -- "HTTPRoute"
  [[ "$out" == *"Deployment"* ]]
}

@test "site served by static-web-server, no metrics port" {
  out=$(render console "$FIX/site.yaml")
  printf '%s' "$out" | grep -qF -- "static-web-server" || [[ "$out" == *"page-fallback"* ]]
  [ -z "$(echo "$out" | yq 'select(.kind=="Deployment").spec.template.spec.containers[0].ports[] | select(.name=="metrics")')" ]
}
