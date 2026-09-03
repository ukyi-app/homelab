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
  mkreg "$reg" '# 사유 — 실행처: owner-local `bats tests/gates/test_scan-floor.bats`' 'tests/gates/test_scan-floor.bats' '' 'tests/gates/test_bats-style.bats'
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
  mkreg "$reg" '# 사유 — 실행처: owner-local `bats tests/gates/test_scan-floor.bats`' 'tests/gates/test_scan-floor.bats' \
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
  # ⚠️ venue는 항목 자기 자신이 아니라 **다른** 실재 파일이어야 한다(자기지시 금지 — 아래 (0a-self)).
  mkreg "$reg" '# docker 의존 — 실행처: owner-local `bats tests/gates/test_bats-accounting.bats`' 'tests/gates/test_scan-floor.bats'
  run bash "$s" --lint-excludes "$reg"
  [ "$status" -eq 0 ]
}

# ── 신설 계약 (0a): 실행처 표기가 가리키는 venue의 **실재** ──────────────────────────────────────
# ⚠️ (0)의 `실행처` 문자열 매칭만 있던 시절, 이 자리는 스크립트 주석이 스스로 "텍스트 계약이지 증명이
#    아니다"라고 적어 둔 구멍이었다. 실측 2026-09-03(착지 전): 없는 타깃(`make no-such-target`)도,
#    아무 단어도(「실행처: 그냥 어딘가에서」) 전부 rc 0이었다. 아래 넷이 그 구멍의 증인이다.

@test "a named venue that does not exist is rejected (the marking must derive, not merely be spelled)" {
  reg="$BATS_TEST_TMPDIR/badvenue"
  mkreg "$reg" '# 사유 — 실행처: `make no-such-target`' 'tests/gates/test_scan-floor.bats'
  run bash "$s" --lint-excludes "$reg"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "venue가 0건 실재"
  # 진단은 그룹 첫 줄과 **인식한 토큰**을 함께 낸다 — 어느 표기가 왜 안 걸렸는지 없이는 고칠 수 없다.
  echo "$output" | grep -q "그룹 첫 줄: # 사유"
  echo "$output" | grep -q "인식한 토큰: \[make no-such-target\]"
}

@test "a venue marking with no recognizable token at all is rejected" {
  reg="$BATS_TEST_TMPDIR/wordonly"
  mkreg "$reg" '# 사유 — 실행처: 그냥 어딘가에서' 'tests/gates/test_scan-floor.bats'
  run bash "$s" --lint-excludes "$reg"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "venue가 0건 실재"
  echo "$output" | grep -q "인식한 토큰: (없음)"
}

@test "each recognized venue form proves a group (make target, bats path, workflow file)" {
  # 음성 대조 — 이 레인이 '표기가 있으면 무조건 red'가 아니라 **실재**를 재는지 고정한다.
  # 셋 다 실 트리의 물건이다: `verify` 타깃 · 이 파일 자신 · iac.yaml(terraform 그룹의 실제 표기).
  reg="$BATS_TEST_TMPDIR/vmake"
  mkreg "$reg" '# 사유 — 실행처: owner-local `make verify`' 'tests/gates/test_scan-floor.bats'
  run bash "$s" --lint-excludes "$reg"
  [ "$status" -eq 0 ]
  reg="$BATS_TEST_TMPDIR/vbats"
  mkreg "$reg" '# 사유 — 실행처: owner-local `bats tests/gates/test_bats-accounting.bats`' 'tests/gates/test_scan-floor.bats'
  run bash "$s" --lint-excludes "$reg"
  [ "$status" -eq 0 ]
  reg="$BATS_TEST_TMPDIR/vwf"
  mkreg "$reg" '# 사유 — 실행처: .github/workflows/iac.yaml (advisory 잡)' 'tests/gates/test_scan-floor.bats'
  run bash "$s" --lint-excludes "$reg"
  [ "$status" -eq 0 ]
}

@test "both backtick and single-quote markings are recognized (the registry mixes them)" {
  # 레지스트리 실측: 대부분 백틱, KSOPS 그룹만 작은따옴표. 파서가 한쪽만 받으면 정직한 표기가 red가 된다.
  reg="$BATS_TEST_TMPDIR/vquote"
  mkreg "$reg" "# 사유 — 실행처: owner-local 'make verify-ksops'" 'tests/gates/test_scan-floor.bats'
  run bash "$s" --lint-excludes "$reg"
  [ "$status" -eq 0 ]
}

@test "a venue named only in unquoted prose does not prove the group (the parser is not a word-matcher)" {
  # 인용 없이 흘린 「make verify」는 산문이지 표기가 아니다 — 여길 열면 (0a)가 다시 텍스트 계약이 된다.
  reg="$BATS_TEST_TMPDIR/vprose"
  mkreg "$reg" '# 사유 — 실행처: 대충 make verify 쯤에서 돈다' 'tests/gates/test_scan-floor.bats'
  run bash "$s" --lint-excludes "$reg"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "venue가 0건 실재"
}

# ── 신설 계약 (0a-self): 자기지시/상호지시는 증명이 아니다(항진식) ───────────────────────────────
# ⚠️ 감사 5라운드 50 critic-venue-tautology 실증: venue_derive는 `bats <경로>` venue를 파일 **존재**로만
#    검증해, 「이 파일이 실행되는 곳: 이 파일」(자기지시)도 「이 파일이 실행되는 곳: 다른 .ci-exclude
#    항목」(상호지시)도 그대로 통과시켰다 — 인용 경로를 무관한 다른 .ci-exclude 항목으로 바꿔도
#    --lint-excludes가 16/16 rc=0로 불변이었다(실측 2026-09-03). 아래 셋이 그 구멍의 증인이다.

@test "a bats venue that cites the item's own path is rejected (self-reference is not proof)" {
  reg="$BATS_TEST_TMPDIR/selfcite"
  mkreg "$reg" '# 사유 — 실행처: owner-local `bats tools/tests/test_dev-postgres.bats`' 'tools/tests/test_dev-postgres.bats'
  run bash "$s" --lint-excludes "$reg"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "venue가 0건 실재"
}

@test "a bats venue that cites ANOTHER .ci-exclude-registered file is also rejected (circular, not external)" {
  # critic의 정확한 뮤테이션: 자기지시를 무관한 **다른 등재 항목**으로 바꿔도 여전히 무증인이어야 한다.
  reg="$BATS_TEST_TMPDIR/crosscite"
  mkreg "$reg" \
    '# 사유A — 실행처: owner-local `bats tests/test_makefile.bats`' 'tools/tests/test_dev-postgres.bats' \
    '# 사유B — 실행처: owner-local `bats tools/tests/test_dev-postgres.bats`' 'tests/test_makefile.bats'
  run bash "$s" --lint-excludes "$reg"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "venue가 0건 실재"
}

@test "a bats venue that cites a real file outside the registry still proves the group" {
  # 음성 대조 — 자기지시 금지가 정당한 외부 venue까지 막으면 안 된다.
  reg="$BATS_TEST_TMPDIR/extcite"
  mkreg "$reg" '# 사유 — 실행처: owner-local `bats tests/gates/test_bats-accounting.bats`' 'tools/tests/test_dev-postgres.bats'
  run bash "$s" --lint-excludes "$reg"
  [ "$status" -eq 0 ]
}

@test "the manual marker self-declares a genuinely absent automated venue" {
  reg="$BATS_TEST_TMPDIR/manual"
  mkreg "$reg" '# 사유 — 실행처: `manual`(owner-local, 자동 venue 0)' 'tools/tests/test_dev-postgres.bats'
  run bash "$s" --lint-excludes "$reg"
  [ "$status" -eq 0 ]
}

# ── 신설 계약 (0b): 레지스트리 상한 ─────────────────────────────────────────────────────────────
# ⚠️ 계약 (0)만으로는 부족하다는 것이 적대 검토로 실측됐다: **기존 유효 그룹 아래**에 이어 붙이는 것은
#    사람이 실제로 쓸 자연스러운 위치이고, 그 위치로 14건을 한 번에 조용히 제외해도 전 가드가 초록이었다
#    (gate 바닥값의 여유분을 정확히 소진하는 합성 공격). 상한이 그 축을 닫는다.

# ⚠️ 상한은 이제 **스크립트 상수**(EXCL_MAX)다 — env 오버라이드(`BATS_EXCLUDE_MAX`)는 폐지됐다(호출부에
#    보이지 않는 off-switch). 그래서 아래 두 픽스처는 상수를 **정적 증인으로 읽어** 자기 크기를 만든다:
#    상수를 올려도 픽스처가 자동 추종하므로 손 수치가 두 곳에서 이중 관리되지 않는다.
#    `--lint-excludes` 모드는 (2) 실재 검사보다 **먼저** 종료하므로 항목 경로는 임의여도 된다.

# 스크립트의 상한 상수를 읽는다(정적 증인 — 읽기 실패는 빈 문자열이라 호출부가 [ -n ]으로 잡는다).
excl_max() { grep -oE '^EXCL_MAX=[0-9]+' "$s" | cut -d= -f2; }

@test "growth under an existing valid group still trips the ceiling" {
  max="$(excl_max)"
  [ -n "$max" ]
  reg="$BATS_TEST_TMPDIR/grow"
  # 상한 + 1건 — 기존 유효 그룹 **아래**에 이어 붙이는 자연스러운 위치 그대로.
  : > "$reg"
  echo '# 사유 — 실행처: owner-local `bats tests/gates/test_scan-floor.bats`' >> "$reg"
  i=0
  while [ "$i" -le "$max" ]; do echo "tests/gates/test_fixture-$i.bats" >> "$reg"; i=$((i + 1)); done
  run bash "$s" --lint-excludes "$reg"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "상한"
}

@test "shrinking the registry below the ceiling passes (a ceiling, not a ratchet)" {
  max="$(excl_max)"
  [ -n "$max" ]
  reg="$BATS_TEST_TMPDIR/shrink"
  mkreg "$reg" '# 사유 — 실행처: owner-local `bats tests/gates/test_bats-accounting.bats`' 'tests/gates/test_scan-floor.bats'
  run bash "$s" --lint-excludes "$reg"
  [ "$status" -eq 0 ]
}

# 상한이 **env로 꺼지지 않는다**는 것 자체가 단언 대상이다 — 폐지 전에는 `BATS_EXCLUDE_MAX=999` 한 줄로
# 상한이 통째로 사라졌고(재현: 20건 레지스트리 rc 1 → env 붙이면 rc 0) 그걸 재는 증인이 0건이었다.
@test "the ceiling cannot be lifted by an environment variable (no invisible off-switch)" {
  max="$(excl_max)"
  [ -n "$max" ]
  reg="$BATS_TEST_TMPDIR/envoff"
  : > "$reg"
  echo '# 사유 — 실행처: owner-local `bats tests/gates/test_scan-floor.bats`' >> "$reg"
  i=0
  while [ "$i" -le "$max" ]; do echo "tests/gates/test_fixture-$i.bats" >> "$reg"; i=$((i + 1)); done
  BATS_EXCLUDE_MAX=999 run bash "$s" --lint-excludes "$reg"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "상한"
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
  mkreg "$reg" '# 사유 — 실행처: owner-local `bats tests/gates/test_scan-floor.bats`' 'tests/gates/test_scan-floor.bats'
  fix="$(bash "$s" --lint-excludes "$reg" | sed -n 's/^SCAN: check-bats-accounting:excludes: //p')"
  real="$(bash "$s" | sed -n 's/^SCAN: check-bats-accounting:excludes: //p')"
  [ -n "$fix" ]
  [ -n "$real" ]
  [ "$fix" -ne "$real" ]
}
