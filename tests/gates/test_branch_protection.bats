#!/usr/bin/env bats
# supplychain-1(부분): main 분기보호의 게이트 불변식이 무인으로 약화되지 못하게 한다.
#  - required_status_checks.contexts 가 "gate" 를 포함(auto-merge 폴백의 유일 required check).
#  - strict == true (머지 전 브랜치가 base에 최신 — stale 통과 차단).
#  - enforce_admins == false 가 의도된 솔로-오너 잔여 우회임을 주석으로 문서화.
# dispositions 준수: review_count=1 / require_last_push_approval=true 는 단언하지 않는다
# (솔로-오너 auto-merge 파괴 / count=0에서 no-op).

TF="$BATS_TEST_DIRNAME/../../infra/github/repo.tf"

# ⚠️ **존재 단언은 행 선두로 앵커한다.** terraform에서 설정을 임시 비활성화하는 표준 편집이 `#`
#    주석인데, 무앵커 grep은 주석 처리된 키를 활성 키와 구별하지 못한다. 실측 2026-09-03:
#    repo.tf:42-43을 `# strict   = true (일시 비활성)`·`# contexts = ["gate"] (일시 비활성)`로
#    바꿔 `required_status_checks {}`를 빈 블록으로 만들어도 이 파일이 4/4 green이었다.
#    `gate`는 이 레포의 유일한 required check이고(docs/decisions/0003) repo.tf는 owner-local
#    apply 루트라 라이브 반영도 조용하다 — 레포 전역에 대체 증인이 0건이다.
# ⚠️ 반대로 **부재 단언(:strict=false)에는 앵커를 붙이지 않는다** — 부정 판정을 좁히면 위반의
#    정의가 줄어 가드가 약해진다.
@test "required_status_checks.contexts includes gate" {
  # contexts 줄에 "gate" 가 있어야 한다(required check SSOT).
  run grep -E '^[[:space:]]*contexts[[:space:]]*=.*"gate"' "$TF"
  [ "$status" -eq 0 ]
}

@test "required_status_checks strict is true" {
  # strict=true: base에 뒤처진 브랜치의 stale 통과를 막는다.
  run grep -E '^[[:space:]]*strict[[:space:]]*=[[:space:]]*true' "$TF"
  [ "$status" -eq 0 ]
}

@test "branch protection block does NOT set strict=false anywhere" {
  # 무인 relaxation 회귀 가드: strict=false 가 절대 등장하지 않아야 한다.
  run grep -E 'strict[[:space:]]*=[[:space:]]*false' "$TF"
  # rc 2(파일 부재)를 통과로 읽지 않는다 — grep 무매치는 정확히 rc 1이다.
  [ "$status" -eq 1 ]
}

@test "enforce_admins=false is documented as a deliberate solo-owner residual bypass" {
  # 잔여 위험을 코드에 명시(미문서 우회로 오인 방지). 주석에 '잔여' 또는 'residual' + 'enforce_admins'.
  # ⚠️ 키는 **실제 대입 줄**로 앵커한다 — 무앵커면 이 설정을 설명하는 주석(repo.tf:49)만으로도
  #    만족돼 키가 사라진 상태를 못 본다. 문서화 어휘는 주석에 사는 것이 정상이라 앵커 없이 둔다.
  run grep -nE '^[[:space:]]*enforce_admins[[:space:]]*=' "$TF"
  [ "$status" -eq 0 ]
  run grep -niE '솔로|residual|잔여' "$TF"
  [ "$status" -eq 0 ]
}
