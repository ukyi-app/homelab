#!/usr/bin/env bats
# drift-1: iac.yaml의 primary merge→apply 경로(apply job)는 plan과 apply 사이에 tf-destroy-guard
# (mode=block)를 거쳐야 한다. iac-plan preview는 동일 composite를 mode=warn으로 쓴다.
# ⚠️ bash 3.2: 중간 단언은 [ ]만. 순수 grep — terraform/cluster 비접촉(required gate-safe).

WF="$BATS_TEST_DIRNAME/../../.github/workflows/iac.yaml"

@test "apply job uses tf-destroy-guard with mode=block" {
  # apply job 블록(plan→apply 사이)에 composite + block 모드가 있어야 한다.
  run grep -q 'uses: ./.github/actions/tf-destroy-guard' "$WF"
  [ "$status" -eq 0 ]
  run grep -qE 'mode:[[:space:]]*block' "$WF"
  [ "$status" -eq 0 ]
}

@test "apply job no longer applies without a guard (apply preceded by guard usage)" {
  # apply 스텝과 guard 사용이 같은 워크플로에 공존 — guard 미사용 회귀를 차단.
  run grep -c 'uses: ./.github/actions/tf-destroy-guard' "$WF"
  [ "$status" -eq 0 ]
  [ "$output" -ge 2 ]   # apply(block) + iac-plan preview(warn) 두 콜사이트
}

@test "iac-plan preview uses tf-destroy-guard mode=warn (not an inline jq block)" {
  run grep -qE 'mode:[[:space:]]*warn' "$WF"
  [ "$status" -eq 0 ]
  # 인라인 destroy jq 셀렉터는 composite로 옮겨졌어야 한다(워크플로에서 제거).
  run grep -F 'select(. == "delete")' "$WF"
  [ "$status" -ne 0 ]
}
