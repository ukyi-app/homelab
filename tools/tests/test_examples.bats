#!/usr/bin/env bats
# kind별 차트 렌더 계약 검증 — 차트 자체 fixtures 사용.
# 앱 배포 values(apps/<name>/deploy/prod)는 참조하지 않는다 — 앱 코드가 외부 레포에 살아 이 레포의
# values는 배포 설정일 뿐이다. 렌더 계약의 SSOT는 차트 fixtures다.
# ⚠️ 메모리는 이 파일 소관이 아니다 — 앱 사이징은 platform/charts/app/values.schema.json이
#    resources 4값(requests/limits × cpu/memory)을 required로 강제하고, 그 증인은
#    platform/charts/app/tests/test_schema.bats:20·44·52(「per-app sizing gate」·「sizing-discipline
#    divergence (limits half)」·「emptied or absent requests axis」)다. :44는 limits 축만 재므로
#    requests 축 증인은 :52다 — 한 증인에 두 축을 걸면 절반이 무증인으로 남는다.
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
