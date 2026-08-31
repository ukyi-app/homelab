#!/usr/bin/env bats
# audit 스케줄 reconciler(audit.yaml) 불변식. 구 audit reusable 워크플로에서 이관된 단언 포함.
# (@test 이름 영어, 단언은 grep/run+[ ] — bash 3.2 [[ ]] 침묵통과 함정 회피)

setup() { ROOT="$(git rev-parse --show-toplevel)"; F="$ROOT/.github/workflows/audit.yaml"; }

@test "audit is a scheduled reconciler with manual dispatch" {
  [ -f "$F" ]; grep -q "schedule:" "$F"; grep -q "workflow_dispatch:" "$F"
}
@test "audit notifies only on alerting drift or failure (no zero-count spam, report-only excluded)" {
  # B: 텔레그램 게이트는 count가 아니라 alerting(report-only 제외)으로 — activation-surface-drift 같은
  # 이미지 bump 재발 정보성 드리프트는 페이지하지 않는다(감사 JSON엔 유지). 옛 count 게이트는 없어야 한다.
  grep -q "alerting != '0'" "$F"
  # rc 2(audit.yaml 리네임/삭제)를 "옛 count 게이트 없음"으로 읽지 않는다 — 위 줄이 같은 파일의 실재를
  # 증언한다. cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③
  run grep -q "outputs.count != '0'" "$F"; [ "$status" -eq 1 ]
}
@test "audit sources the alerting gate from the tool (report-only set is SSOT in audit-orphans)" {
  # alerting은 tools/audit-orphans.ts가 산출(REPORT_ONLY 제외) — 워크플로는 jq로 읽기만.
  grep -q 'jq -r .alerting' "$F"
  grep -q 'REPORT_ONLY' "$ROOT/tools/audit-orphans.ts"
  grep -q 'activation-surface-drift' "$ROOT/tools/audit-orphans.ts"
}
@test "audit status is outcome-driven (failure not mislabeled as drift)" {
  grep -q "steps.audit.outcome == 'failure'" "$F"
}
@test "audit is read-only and not in the mutation serialization group" {
  # ⚠️ 이 @test엔 형제 양성 단언이 없다 — audit.yaml이 사라지면 "직렬화 그룹에 없다"가 대상 없이
  #    초록이었다. 단일 파일 피연산자라 `-eq 1`이 rc 2를 red로 가른다.
  #    cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③
  run grep -q "group: homelab-mutation" "$F"; [ "$status" -eq 1 ]
}
@test "audit summary does not cap findings at 20" {
  run grep -c '\.findings\[:20\]' "$F"; [ "$output" = "0" ]
}
@test "audit summary does not swallow jq errors" {
  run grep -cE '2>/dev/null \|\| true' "$F"; [ "$output" = "0" ]
}
