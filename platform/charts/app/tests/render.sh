#!/usr/bin/env bash
set -euo pipefail
CHART="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$CHART/../../.." && pwd)"
REGO="$CHART/tests/psa-restricted.rego"
fail=0
# 빈 렌더 양성 대조 — 이 파일의 두 검증(kubeconform·conftest)은 **빈 입력에 전부 rc 0**이다
# (실측: `printf '' | kubeconform …` → "0 resource found · Valid: 0" rc 0 · `printf '' | conftest …`
#  → "10 tests, 10 passed" rc 0). 2026-08-29 격리 트리 M1(templates/ 3파일을 0바이트로) 실측에서
# render.sh 전체가 rc 0이었고 렌더를 재는 @test 7건도 함께 초록이었다 — 이 레포가 '최악'으로 정의한
# vacuous green이다. 처방은 test_route.bats의 선례 그대로 **자리마다 한 줄 양성 대조**다.
# ⚠️ kind별 문서 수(want=3/1) 카운트는 쓰지 않는다 — 손 관리 수치는 반드시 드리프트한다
#    (scripts/lib/scan-floor.sh의 규율). 세 kind 전부 Deployment를 정확히 하나 내므로 그 존재만 잰다.
# ⚠️ herestring이다 — `printf … | grep -q`는 pipefail 아래에서 writer를 SIGPIPE로 죽인다
#    (docs/traps-detail.md 「`grep -q`의 조기 종료…」, 이 파일도 :2 set -o pipefail이다).
render_or_fail() { # $1=라벨 · $2=렌더 출력
  grep -q '^kind: Deployment' <<<"$2" \
    || { echo "FAIL: $1 렌더가 Deployment를 내지 않았다(빈 렌더 — 아래 검증은 빈 입력에 전부 rc 0이다)"; fail=1; }
}
for k in web worker site; do
  echo "== rendering kind=$k =="
  out="$(helm template t "$CHART" -f "$CHART/tests/fixtures/$k.yaml")"
  render_or_fail "kind=$k" "$out"
  echo "$out" | kubeconform -strict -summary -ignore-missing-schemas \
        -schema-location default \
        -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
    || fail=1
  # PSA restricted 패리티(라이브 admission과 동일 기준) — 스키마가 못 잡는 약화를 렌더 파드에서 차단.
  echo "$out" | conftest test --policy "$REGO" - || fail=1
done
# 실제 앱 deploy values도 동일 conftest로 (적대 리뷰 Pass3 #3 — fixture만으론 앱 values 미커버).
# 인-레포 앱 0이면 glob 미매치 → no-op(첫 앱부터 강제 계약).
# ⚠️ kubeconform도 fixture 루프와 **같은 스키마 URL로** 돌린다. 앱 values의 스키마-밖 리프 오타
#    (envFrom `secretRe`·livenessProbe·securityContext `readOnlyRootFilesystm` 등)는 values.schema.json이
#    그 자리를 `{"type":"object"}`로 열어 둬 helm을 통과하고, conftest는 PSA 축만 보므로 통과한다 —
#    실측: helm rc 0 · conftest 30/30 passed · kubeconform -strict만 "additional properties … not allowed".
#    잡히는 자리가 없으면 그 오타는 ArgoCD SSA(ServerSideApply=true)의 strict 디코딩에서, 즉 PR gate가
#    아니라 **배포 시점**에 SyncFailed로 드러난다(AGENTS.md 「SSA … 스키마 밖 필드 거부」의 재발 경로).
for vals in "$ROOT"/apps/*/deploy/prod/values.yaml; do
  [ -f "$vals" ] || continue
  app="$(echo "$vals" | sed -E 's#.*/apps/([^/]+)/.*#\1#')"
  echo "== rendering app=$app (deploy/prod values) =="
  out="$(helm template "$app" "$CHART" -f "$vals")"
  render_or_fail "app=$app" "$out"
  echo "$out" | kubeconform -strict -summary -ignore-missing-schemas \
        -schema-location default \
        -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
    || fail=1
  echo "$out" | conftest test --policy "$REGO" - || fail=1
done
exit $fail
