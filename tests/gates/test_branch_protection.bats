#!/usr/bin/env bats
# supplychain-1(부분): main 분기보호의 게이트 불변식이 무인으로 약화되지 못하게 한다.
#  - required_status_checks.contexts 가 "gate" 를 포함(auto-merge 폴백의 유일 required check).
#  - strict == true (머지 전 브랜치가 base에 최신 — stale 통과 차단).
#  - enforce_admins == false 가 의도된 솔로-오너 잔여 우회임을 주석으로 문서화.
# dispositions 준수: review_count=1 / require_last_push_approval=true 는 단언하지 않는다
# (솔로-오너 auto-merge 파괴 / count=0에서 no-op).

TF="$BATS_TEST_DIRNAME/../../infra/github/repo.tf"

@test "required_status_checks.contexts includes gate" {
  # contexts 줄에 "gate" 가 있어야 한다(required check SSOT).
  run grep -E 'contexts[[:space:]]*=.*"gate"' "$TF"
  [ "$status" -eq 0 ]
}

@test "required_status_checks strict is true" {
  # strict=true: base에 뒤처진 브랜치의 stale 통과를 막는다.
  run grep -E 'strict[[:space:]]*=[[:space:]]*true' "$TF"
  [ "$status" -eq 0 ]
}

@test "branch protection block does NOT set strict=false anywhere" {
  # 무인 relaxation 회귀 가드: strict=false 가 절대 등장하지 않아야 한다.
  run grep -E 'strict[[:space:]]*=[[:space:]]*false' "$TF"
  [ "$status" -ne 0 ]
}

@test "enforce_admins=false is documented as a deliberate solo-owner residual bypass" {
  # 잔여 위험을 코드에 명시(미문서 우회로 오인 방지). 주석에 '잔여' 또는 'residual' + 'enforce_admins'.
  run grep -nE 'enforce_admins' "$TF"
  [ "$status" -eq 0 ]
  run grep -niE '솔로|residual|잔여' "$TF"
  [ "$status" -eq 0 ]
}
