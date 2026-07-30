#!/usr/bin/env bats
# check-bats-accounting의 **레지스트리 계약** gate 테스트 — 탐지기가 스스로 vacuous하지 않음을 픽스처로
# 증명한다(선례: test_bats-style.bats).
#
# 왜 이 파일이 생겼나: `tests/.ci-exclude` 헤더는 "각 그룹 주석이 실행처를 명시한다(accounting 가드가
# 강제)"라고 **주장만** 하고 있었다. 실측(2026-07-30): 가드는 `#` 줄을 건너뛰기만 했고 주석을 한 번도
# 읽지 않았다. 사유 없이 한 줄 추가해도, 주석을 전부 지워도, gate 208건 중 81건을 옮겨도 전 가드가
# 초록이었다. 이 파일은 그 계약이 이제 **실제로** 강제되는지를 픽스처로 못박는다.
#
# ⚠️ @test 이름은 영어만(한글이면 bats dir-run 인코딩 깨짐 — AGENTS.md).
# ⚠️ 중간 단언은 [ ]/grep만(bash 3.2 [[ ]] 실패 침묵통과 — AGENTS.md).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1
  s="$ROOT/scripts/check-bats-accounting.sh"
}

# 픽스처 레지스트리를 만든다(첫 인자 = 파일 경로, 나머지 = 줄들).
mkreg() { f="$1"; shift; printf '%s\n' "$@" > "$f"; }

@test "the real tree passes the full accounting" {
  run bash "$s"
  [ "$status" -eq 0 ]
}

# ── 신설 계약 (0): 사유 그룹 주석 지배 + 실행처 표기 ────────────────────────────────────────────

@test "a bare entry with no governing comment is rejected" {
  reg="$BATS_TEST_TMPDIR/bare"
  mkreg "$reg" '# 사유 — 실행처: owner-local' 'tests/gates/test_scan-floor.bats' '' 'tests/gates/test_bats-style.bats'
  run bash "$s" --lint-excludes "$reg"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "사유 그룹 주석 없이"
}

@test "a governing comment without the execution-venue token is rejected" {
  reg="$BATS_TEST_TMPDIR/novenue"
  mkreg "$reg" '# 그냥 빼고 싶어서' 'tests/gates/test_scan-floor.bats'
  run bash "$s" --lint-excludes "$reg"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "실행처 표기 없음"
}

# ⚠️ 이 규칙을 쓰면서 실제로 낸 버그다: 주석을 누적만 하면 **새 그룹 헤더가 앞 그룹의 실행처 표기를
#    물려받아** 통과한다. 항목 뒤의 주석은 새 그룹을 열어야 한다.
@test "a comment following an entry opens a new group instead of inheriting the previous one" {
  reg="$BATS_TEST_TMPDIR/inherit"
  mkreg "$reg" '# 사유 — 실행처: owner-local' 'tests/gates/test_scan-floor.bats' \
               '# 새 사유(표기 없음)' 'tests/gates/test_bats-style.bats'
  run bash "$s" --lint-excludes "$reg"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "실행처 표기 없음"
}

@test "the file header does not govern entries below a blank line" {
  reg="$BATS_TEST_TMPDIR/header"
  mkreg "$reg" '# 파일 헤더 — 실행처 어쩌구' '' 'tests/gates/test_scan-floor.bats'
  run bash "$s" --lint-excludes "$reg"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "사유 그룹 주석 없이"
}

@test "a well-formed registry passes the contract" {
  reg="$BATS_TEST_TMPDIR/ok"
  mkreg "$reg" '# docker 의존 — 실행처: owner-local bats' 'tests/gates/test_scan-floor.bats'
  run bash "$s" --lint-excludes "$reg"
  [ "$status" -eq 0 ]
}

# ── 신설 계약 (0b): 레지스트리 상한 ─────────────────────────────────────────────────────────────
# ⚠️ 계약 (0)만으로는 부족하다는 것이 적대 검토로 실측됐다: **기존 유효 그룹 아래**에 이어 붙이는 것은
#    사람이 실제로 쓸 자연스러운 위치이고, 그 위치로 14건을 한 번에 조용히 제외해도 전 가드가 초록이었다
#    (gate 바닥값의 여유분을 정확히 소진하는 합성 공격). 상한이 그 축을 닫는다.

@test "growth under an existing valid group still trips the ceiling" {
  reg="$BATS_TEST_TMPDIR/grow"
  mkreg "$reg" '# 사유 — 실행처: owner-local' \
               'tests/gates/test_scan-floor.bats' 'tests/gates/test_bats-style.bats' 'tests/gates/test_make-help.bats'
  BATS_EXCLUDE_MAX=2 run bash "$s" --lint-excludes "$reg"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "상한"
}

@test "shrinking the registry below the ceiling passes (a ceiling, not a ratchet)" {
  reg="$BATS_TEST_TMPDIR/shrink"
  mkreg "$reg" '# 사유 — 실행처: owner-local' 'tests/gates/test_scan-floor.bats'
  BATS_EXCLUDE_MAX=9 run bash "$s" --lint-excludes "$reg"
  [ "$status" -eq 0 ]
}

@test "the committed registry is at or under its own ceiling with no override" {
  # 실 레지스트리에 대한 판정 — 픽스처만 재고 실물은 아무도 안 보는 상태를 막는다.
  run bash "$s" --lint-excludes "$ROOT/tests/.ci-exclude"
  [ "$status" -eq 0 ]
}

# ── 픽스처 모드가 회계를 끄는 off-switch가 아님 ─────────────────────────────────────────────────
# ⚠️ 앞선 판은 `if [ "$#" -gt 0 ]`로 **첫 인자**를 레지스트리 경로로 삼았다. 그러면 아무 토큰이나 하나
#    붙는 순간 도메인 회계와 gate 바닥값이 통째로 건너뛰어지고 exit 0이 된다 — 소비처가 셋이라(ci.yaml·
#    Makefile 2곳) 어디든 인자 한 토큰이면 이 가드가 자기 자신을 끄는 스위치가 됐다(적대 검토 실측).

@test "an unknown argument fails loud instead of silently degrading to lint mode" {
  run bash "$s" tests/.ci-exclude
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "알 수 없는 인자"
}

@test "the lint flag requires its file argument" {
  run bash "$s" --lint-excludes
  [ "$status" -eq 2 ]
}

@test "a missing registry file fails loud" {
  run bash "$s" --lint-excludes "$BATS_TEST_TMPDIR/nope-$$"
  [ "$status" -eq 2 ]
}

# ── 스캔 신호 규약 ───────────────────────────────────────────────────────────────────────────────

@test "the default run emits all three domain scan markers" {
  run bash "$s"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^SCAN: check-bats-accounting:excludes: [0-9]+$'
  echo "$output" | grep -qE '^SCAN: check-bats-accounting:gate: [0-9]+$'
  echo "$output" | grep -qE '^SCAN: check-bats-accounting:tracked: [0-9]+$'
}

@test "a fixture lint reports a different exclude count than the real registry" {
  # 08-a의 목적: 이 호출이 **실 도메인에 닿았는가**를 건수 대비로 가른다(같은 라벨·다른 값).
  reg="$BATS_TEST_TMPDIR/contrast"
  mkreg "$reg" '# 사유 — 실행처: owner-local' 'tests/gates/test_scan-floor.bats'
  fix="$(bash "$s" --lint-excludes "$reg" | sed -n 's/^SCAN: check-bats-accounting:excludes: //p')"
  real="$(bash "$s" | sed -n 's/^SCAN: check-bats-accounting:excludes: //p')"
  [ -n "$fix" ]
  [ -n "$real" ]
  [ "$fix" -ne "$real" ]
}
