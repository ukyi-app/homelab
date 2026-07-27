#!/usr/bin/env bats
# bats 네이밍 컨벤션 가드 — 모든 추적 *.bats는 test_ 접두여야 한다(run-bats.sh 수집 글롭 전제).
# 미접두 bats는 단일 러너 수집에서 조용히 빠질 수 있으므로 게이트에서 시끄럽게 실패시킨다.
# bash 3.2 함정: 단언은 [ ] (단순 명령)로.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; }

@test "every tracked *.bats starts with test_ (collection convention guard)" {
  # ⚠️ 바닥값이 먼저다 — 열거가 0건이면 "전건 접두 준수"와 "아무것도 안 봤다"가 같은 초록이다.
  # 이 가드 위에 check-bats-accounting(F6: 테스트가 어느 harness에도 안 묶여 조용히 죽는 것)이 얹혀 있어
  # 여기가 무너지면 그 전제까지 함께 사라진다.
  run bash -c "git -C '$ROOT' ls-files '*.bats' | grep -c . || true"
  [ "$status" -eq 0 ]
  [ "$output" -ge 120 ]   # 현재 추적 229건 — 절반으로 줄어도 안 걸린다. 래칫 아님
  run bash -c "git -C '$ROOT' ls-files '*.bats' | grep -vE '(^|/)test_[^/]*\.bats$' || true"
  [ -z "$output" ]   # 접두 없는 bats가 하나라도 있으면 실패
}

@test "check-skeleton.sh wires the bats naming guard (not a no-op)" {
  run grep -qE 'test_\[\^/\]|test_ 접두|bats' "$ROOT/scripts/check-skeleton.sh"
  [ "$status" -eq 0 ]
}
