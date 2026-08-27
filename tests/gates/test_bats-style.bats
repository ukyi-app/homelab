#!/usr/bin/env bats
# bats 단언-스타일 가드의 gate 테스트 — 탐지기가 스스로 vacuous하지 않음을 fixture로 증명(선례: test_bats-naming.bats).
# ⚠️ 중간 단언은 [ ]만(bash 3.2 [[ ]] 침묵 통과 — 이 파일이 막으려는 바로 그 함정).
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; }

@test "check-bats-style passes on the current tree (no middle negations, [[ ]] within baseline)" {
  run bash "$ROOT/scripts/check-bats-style.sh"
  [ "$status" -eq 0 ]   # B3.2가 NEG를 0으로 만든 뒤 통과
}

@test "the detector failing (awk fatal or an unreadable arg) is red, not a silent pass" {
  # ★ 예전엔 `findings="$(awk … || true)"`라 검출기가 죽어도 "0곳 OK" rc=0이었다 — 가드 본체의
  #   fail-open이다(2026-08-24 뮤테이션으로 실증). 형제 check-host-ports.sh가 닫은 것과 같은 클래스.
  #   awk를 직접 못 죽이므로 검출기가 fatal을 내는 유일한 결정적 경로 — 읽을 수 없는 인자 — 를 쓴다.
  run bash "$ROOT/scripts/check-bats-style.sh" "$BATS_TEST_TMPDIR/does-not-exist.bats"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF 'FAIL'
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
# 가르지 못하면 이 가드가 죽어도 게이트가 초록이다.
# ⚠️ 채널은 **skip이 아니라 열거 붕괴**다 — 기본 모드 도메인(추적 *.bats 229건)은 정당하게 0이 될 수
# 없다. 같은 도메인의 형제(check-skeleton·check-bats-accounting)가 exit 1 바닥값이라, 여기서 exit 4 +
# `SKIP:`를 내면 "정당하게 대상 없음(미평가·정상)"으로 정반대로 읽힌다(적대 검토 확정).
# 픽스처 = 스크립트 + 커널을 복사한 빈 git 레포(스크립트가 ROOT를 BASH_SOURCE/..로 잡는다).
@test "fails as enumeration collapse (not skip) when no bats files are tracked" {
  FIX="$BATS_TEST_TMPDIR/emptyrepo"
  mkdir -p "$FIX/scripts/lib"
  cp "$ROOT/scripts/check-bats-style.sh" "$FIX/scripts/"
  cp "$ROOT/scripts/lib/scan-floor.sh" "$FIX/scripts/lib/"
  cp "$ROOT/scripts/lib/guard.sh" "$FIX/scripts/lib/"
  git -C "$FIX" init -q
  run bash "$FIX/scripts/check-bats-style.sh"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "열거 붕괴"
  out="$output"
  run grep -q "^SKIP:" <<<"$out"
  [ "$status" -ne 0 ]
}

@test "evaluates (no SKIP marker, no collapse) when the tracked bats domain is non-empty" {
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

@test "a comment quoting a heredoc marker does not blind the detector to a middle negation" {
  # 형제 check-locale-collation.sh와 같은 순서 결함 — heredoc 상태 기계가 주석 스킵보다 먼저 돌면
  # 인용된 heredoc 표기 한 줄이 @test의 나머지를 통째로 지운다(docs/traps-detail.md 1490).
  # 이 파일 도메인(*.bats)에서 착지 전 실측 5파일 602줄이 그렇게 투명했다.
  # ⚠️ 표기를 런타임에 조립한다 — 리터럴로 적으면 이 파일 자신이 검출기에게 투명해진다.
  hd='<'; hd="$hd$hd"
  printf '%s\n' \
    '@test "quoted heredoc marker in a comment" {' \
    "  # 예전엔 python3 - ${hd}PY 로 했다" \
    '  run echo hi' \
    '  ! echo "$output" | grep -q zzz' \
    '  [ "$status" -eq 0 ]' \
    '}' > "$BATS_TEST_TMPDIR/test_cmt_hd.bats"
  run bash "$ROOT/scripts/check-bats-style.sh" "$BATS_TEST_TMPDIR/test_cmt_hd.bats"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '\[NEG\]'
}
