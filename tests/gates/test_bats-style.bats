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

# 도메인(추적 *.bats)이 비면 통과가 아니라 SKIP이다 — 수집이 깨져 0건이 된 것과 "검사했고 깨끗함"을
# 가르지 못하면 이 가드가 죽어도 게이트가 초록이다(CONTRIBUTING '가드 skip 신호').
# 픽스처 = 스크립트를 복사한 빈 git 레포(스크립트가 ROOT를 BASH_SOURCE/..로 잡는다).
@test "signals skip (exit 4 + SKIP marker) when no bats files are tracked" {
  FIX="$BATS_TEST_TMPDIR/emptyrepo"
  mkdir -p "$FIX/scripts"
  cp "$ROOT/scripts/check-bats-style.sh" "$FIX/scripts/"
  git -C "$FIX" init -q
  run bash "$FIX/scripts/check-bats-style.sh"
  [ "$status" -eq 4 ]
  echo "$output" | grep -q "^SKIP: check-bats-style:"
}

@test "evaluates (no SKIP marker) when the tracked bats domain is non-empty" {
  run bash "$ROOT/scripts/check-bats-style.sh"
  [ "$status" -eq 0 ]
  out="$output"
  run grep -q "^SKIP:" <<<"$out"
  [ "$status" -ne 0 ]
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
