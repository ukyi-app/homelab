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
@test "audit sources the alerting gate from the tool (REPORT_ONLY set is SSOT in audit-orphans)" {
  # alerting은 tools/audit-orphans.ts가 산출(REPORT_ONLY 제외) — 워크플로는 jq로 읽기만.
  grep -q 'jq -r .alerting' "$F"
  grep -q 'REPORT_ONLY' "$ROOT/tools/audit-orphans.ts"
  grep -q 'activation-surface-drift' "$ROOT/tools/audit-orphans.ts"
}
@test "audit status is outcome-driven (failure not mislabeled as drift)" {
  # 긍정 가드여야 한다 — `== 'failure'`만 보면 checkout/setup-bun 같은 **상류 스텝** 실패에서
  # audit이 outcome=skipped라 첫 분기가 거짓이고, outputs가 ''이라 `'' != '0'`이 참이 되어
  # 실행 실패가 'drift'(⚠️ 경고)로 오라벨된다. status·ident·폴백 body 셋 다 같은 가드다.
  # (형태 일반화는 tests/gates/test_telegram-callsites.bats가 전 콜사이트에 건다.)
  grep -qF "status: \${{ steps.audit.outcome == 'success'" "$F"
  grep -qF "ident: \${{ steps.audit.outcome == 'success'" "$F"
  grep -qF '[ "$OUTCOME" != "success" ]' "$F"
}
@test "audit is read-only and not in the mutation serialization group" {
  # ⚠️ 이 @test엔 형제 양성 단언이 없다 — audit.yaml이 사라지면 "직렬화 그룹에 없다"가 대상 없이
  #    초록이었다. 단일 파일 피연산자라 `-eq 1`이 rc 2를 red로 가른다.
  #    cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③
  run grep -q "group: homelab-mutation" "$F"; [ "$status" -eq 1 ]
  # exact-tools-infra-4(5라운드) — "read-only" 축은 위 직렬화 그룹 부재 하나뿐이라, 워크플로
  # permissions에 contents:write+pull-requests:write를 부여해도 무증인이었다(rc 2/false 구분
  # 위해 yq 형제 관용구 — tools/tests/test_reusable-app-build.bats:85-86과 동형).
  [ "$(yq -r '.permissions | to_entries | map(select(.value != "read")) | length' "$F")" = "0" ]
  [ "$(yq -r '.jobs.audit.permissions // "absent"' "$F")" = "absent" ]
  # ⚠️ 이 레포의 실제 writer 레버는 GITHUB_TOKEN이 아니라 App 토큰이다(bump-poll.yaml:16-17은
  #    contents: read인 채 :91-92로 main을 쓴다) — 권한 축만 재면 절반만 막힌다.
  run grep -q 'create-github-app-token' "$F"; [ "$status" -eq 1 ]
}
@test "audit summary does not cap findings at 20" {
  run grep -c '\.findings\[:20\]' "$F"; [ "$output" = "0" ]
}
@test "audit summary does not swallow jq errors" {
  run grep -cE '2>/dev/null \|\| true' "$F"; [ "$output" = "0" ]
}
