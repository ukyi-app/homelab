#!/usr/bin/env bats
# check-skeleton 바닥값 어휘(kernel-followups 02) — env 폐지 + --floor 수용의 행동 증인.
# ⚠️ 형제 test_check-skeleton-gate.bats와 분리한 이유: 그쪽 setup은 yq 부재 시 파일 전역 skip인데
#    이 증인들은 yq 무관이라, 같이 두면 로컬 yq 미설치에서 조용히 vacuous가 된다(리뷰 지적 —
#    "skip이 단언을 만족하는" 클래스). ⚠️ @test 이름은 영어 · 중간 단언은 [ ]만.

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "the skeleton floors answer to --floor and a collapse withholds the marker" {
  run bash "$ROOT/scripts/check-skeleton.sh" --floor bats=99999
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "check-skeleton:bats.*열거 붕괴"
  out="$output"
  run grep -q "^SCAN: check-skeleton:bats:" <<<"$out"
  [ "$status" -ne 0 ]
}

@test "the retired skeleton env floors are inert (an exported knob cannot silently raise or drop a floor)" {
  # env는 호출부에 보이지 않는 채로 바닥값을 조작한다 — 폐지 후에는 무시되어야 한다(spec 결정 1).
  run env SKELETON_BATS_MIN_SCAN=99999 bash "$ROOT/scripts/check-skeleton.sh"
  [ "$status" -eq 0 ]
}

@test "an unknown argument is a usage error (the new argv loop is load-bearing)" {
  # 이관 전에는 argv 루프가 아예 없어 어떤 인자든 조용히 무시됐다 — 신설 거부의 증인.
  run bash "$ROOT/scripts/check-skeleton.sh" --bogus
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "unknown arg"
}

@test "a hyphenated suffix key resolves to its own domain (nul-scan does not misbind)" {
  # 다중 도메인 접미사 해소의 실 가드 증인 — platform은 통과 마커를 내고 nul-scan만 붕괴한다.
  run bash "$ROOT/scripts/check-skeleton.sh" --floor nul-scan=99999
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "check-skeleton:nul-scan.*열거 붕괴"
  echo "$output" | grep -q "^SCAN: check-skeleton:platform:"
  out="$output"
  run grep -q "^SCAN: check-skeleton:nul-scan:" <<<"$out"
  [ "$status" -ne 0 ]
}
