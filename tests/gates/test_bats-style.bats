#!/usr/bin/env bats
# bats 단언-스타일 가드의 gate 테스트 — 탐지기가 스스로 vacuous하지 않음을 fixture로 증명(선례: test_bats-naming.bats).
# ⚠️ 중간 단언은 [ ]만(bash 3.2 [[ ]] 침묵 통과 — 이 파일이 막으려는 바로 그 함정).
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; }

@test "check-bats-style passes on the current tree (no middle negations, [[ ]] within baseline)" {
  run bash "$ROOT/scripts/check-bats-style.sh"
  [ "$status" -eq 0 ]   # B3.2가 NEG를 0으로 만든 뒤 통과
}

@test "detector catches a MIDDLE negation and a MIDDLE [[ ]] (not vacuous)" {
  # ⚠️ fixture는 printf로 생성 — bats 전처리기가 .bats 소스의 heredoc 속 '@test' 줄까지
  #    bats_test_function으로 재작성해 heredoc fixture는 탐지 앵커(^@test)를 잃는다(실측).
  printf '%s\n' \
    '@test "bad middle assertions" {' \
    '  run echo hi' \
    '  ! echo "$output" | grep -q zzz' \
    '  [[ "$output" == *hi* ]]' \
    '  [ "$status" -eq 0 ]' \
    '}' > "$BATS_TEST_TMPDIR/test_bad.bats"
  run bash "$ROOT/scripts/check-bats-style.sh" "$BATS_TEST_TMPDIR/test_bad.bats"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '\[NEG\]'
  echo "$output" | grep -q '\[BB\]'
}

@test "detector allows a LAST-command negation (valid bats idiom)" {
  printf '%s\n' \
    '@test "good last-line negation" {' \
    '  run echo hi' \
    '  [ "$status" -eq 0 ]' \
    '  ! echo "$output" | grep -q zzz' \
    '}' > "$BATS_TEST_TMPDIR/test_good.bats"
  run bash "$ROOT/scripts/check-bats-style.sh" "$BATS_TEST_TMPDIR/test_good.bats"
  [ "$status" -eq 0 ]
}
