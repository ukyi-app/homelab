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

@test "iac.yaml primary apply guard stays block (drift-2 alert-and-skip is reconcile-only)" {
  # primary apply(iac.yaml)는 alert-and-skip로 완화하지 않는다 — 구조적 무인 delete는 여기서 끝까지
  # 막힌다(app 공개 DNS만 allow로 자동 apply, tunnel/zone/waf/r2 등 delete/replace는 block 유지).
  run grep -qE 'mode:[[:space:]]*block' "$WF"
  [ "$status" -eq 0 ]
  run grep -qE 'continue-on-error:[[:space:]]*true' "$WF"
  [ "$status" -ne 0 ]   # iac.yaml apply 경로엔 continue-on-error 없음
}

@test "iac guards pass allow=app-DNS + allow_max cap (both apply+preview)" {
  # cloudflare_dns_record.app[*]만 자동 허용(apex/www=public[*]는 보호), allow_max로 대량 삭제 차단.
  # apply(block) + iac-plan preview(warn) 두 콜사이트 모두 allow와 allow_max를 전달해야 한다.
  na=$(grep -cF 'cloudflare_dns_record\.app' "$WF")
  nm=$(grep -cE '^[[:space:]]+allow_max:' "$WF")
  [ "$na" -ge 2 ] && [ "$nm" -ge 2 ]
}
