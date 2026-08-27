#!/usr/bin/env bats
# 로케일 콜레이션 가드(scripts/check-locale-collation.sh)의 **변별력** 테스트.
# 검출기가 조용히 죽어도(정규식 드리프트·글롭 붕괴) "위반 0곳 OK"는 그대로 나온다 — 그 초록이
# 거짓말이 되지 않게 픽스처로 양성·음성 대조를 매 실행 건다.
# ⚠️ @test 이름은 영어만 · 중간 단언은 [ ]만(bash 3.2 [[ ]] 침묵 통과).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1
  S="$ROOT/scripts/check-locale-collation.sh"
  FX="$BATS_TEST_TMPDIR"
  # heredoc 여는 표기는 lib이 런타임에 조립한다 — 리터럴로 적으면 이 파일이 검출기에게 투명해진다.
  # shellcheck source=tests/gates/lib/heredoc-marker.sh
  . "$ROOT/tests/gates/lib/heredoc-marker.sh"
}

@test "the detector fires on a bare sort -u and stays quiet on a pinned one" {
  printf '#!/usr/bin/env bash\nx="$(printf a | sort -u)"\n'          > "$FX/dirty.sh"
  printf '#!/usr/bin/env bash\ny="$(printf a | LC_ALL=C sort -u)"\n' > "$FX/clean.sh"
  run bash "$S" "$FX/dirty.sh"; [ "$status" -ne 0 ]
  echo "$output" | grep -qF '[A]'
  run bash "$S" "$FX/clean.sh"; [ "$status" -eq 0 ]
}

@test "the detector fires on a bare sort in command position including the closing-paren form" {
  # ⚠️ `| sort)` 형태는 첫 판 정규식이 놓쳐 이 레인을 10건 과소 계수했다(열거 명령 자신의 붕괴).
  #    그 형태를 픽스처에 박아 회귀를 막는다.
  printf '#!/usr/bin/env bash\nx="$(printf a | sort)"\n' > "$FX/paren.sh"
  run bash "$S" "$FX/paren.sh"; [ "$status" -ne 0 ]
  echo "$output" | grep -qF '[B]'
}

@test "numeric sorts and yq filter expressions are not flagged (false-positive control)" {
  # 숫자 정렬은 콜레이션 무관이라 면제다. 단일따옴표 span의 `sort`는 yq/jq 표현식이지 셸 명령이 아니다.
  printf '#!/usr/bin/env bash\na="$(printf 1 | sort -n)"\nb="$(printf 1 | sort -nu)"\n' > "$FX/num.sh"
  run bash "$S" "$FX/num.sh"; [ "$status" -eq 0 ]
  printf '#!/usr/bin/env bash\nc="$(yq %s file.yaml)"\n' "'.a | sort | join(\",\")'" > "$FX/yq.sh"
  run bash "$S" "$FX/yq.sh"; [ "$status" -eq 0 ]
}

@test "the detector fires on JS locale-sensitive comparison APIs" {
  printf 'const x = a.localeCompare(b);\n' > "$FX/dirty.ts"
  run bash "$S" "$FX/dirty.ts"; [ "$status" -ne 0 ]
  echo "$output" | grep -qF '[C]'
  printf 'const y = a < b ? -1 : 1;\n' > "$FX/clean.ts"
  run bash "$S" "$FX/clean.ts"; [ "$status" -eq 0 ]
}

@test "comment lines are not flagged in either shell or TS syntax" {
  printf '#!/usr/bin/env bash\n# 여기서는 sort -u 를 쓰지 마라\n' > "$FX/cmt.sh"
  run bash "$S" "$FX/cmt.sh"; [ "$status" -eq 0 ]
  printf '// localeCompare 는 쓰지 않는다\n' > "$FX/cmt.ts"
  run bash "$S" "$FX/cmt.ts"; [ "$status" -eq 0 ]
}

@test "the explicit-file mode emits its own SCAN signal (floor is exempt, the signal is not)" {
  printf '#!/usr/bin/env bash\n' > "$FX/empty.sh"
  run bash "$S" "$FX/empty.sh"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^SCAN: check-locale-collation: [0-9]+$'
}

@test "the repo tree is clean and the enumeration floor actually engages" {
  run bash "$S"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^SCAN: check-locale-collation: [0-9]+$'
  # 바닥값이 실제로 물리는지 — 도메인이 붕괴하면 초록이 아니라 red여야 한다.
  run bash "$S" --floor check-locale-collation=99999
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "열거 붕괴"
}

@test "the detector failing (an unreadable arg) is red, not a silent pass" {
  # ★ 예전엔 `findings="$(awk … || true)"`라 검출기가 죽어도 "0곳 OK" rc=0이었다 — 가드 본체의
  #   fail-open이다(2026-08-24 뮤테이션으로 실증: awk에 syntax error를 심으면 red 없이 통과했다).
  #   형제 check-host-ports.sh가 닫은 것과 같은 클래스. awk fatal의 결정적 경로 — 읽을 수 없는 인자 — 를 쓴다.
  run bash "$S" "$FX/does-not-exist.sh"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF 'FAIL'
}

@test "the gate venues pin a collation-stable locale" {
  # 런너 고정은 스캐너의 **대체가 아니라 짝**이다 — 고정이 없으면 오너의 en_US와 러너가 서로 다른
  # 술어를 평가하고(실측: sync-wave 원장 가드가 en_US에서 fail-open이었다), 고정만 하면 개별 결함의
  # 뮤테이션 감도가 죽는다(실측: Makefile 회귀가 C.UTF-8에서 초록).
  run grep -qE '^export LC_ALL=C(\.UTF-8)?$|LC_ALL=C\.UTF-8; else export LC_ALL=C' "$ROOT/scripts/run-bats.sh"
  [ "$status" -eq 0 ]
  run yq -e '.env.LC_ALL == "C.UTF-8"' "$ROOT/.github/workflows/ci.yaml"
  [ "$status" -eq 0 ]
}

@test "lane D: a scripts guard missing guard_init is a violation (prologue omission goes red)" {
  # d2(11) — 새 가드가 프롤로그 커널(guard_init)을 건너뛰면 LC_ALL 전역 export가 빠져 이 가드가
  # 잡는 바로 그 병(로케일 의존 콜레이션)의 신설 표면이 된다. 가드 모양(check-/verify- 접두)의
  # 파일은 guard_init 호출이 정적으로 강제된다.
  mkdir -p "$BATS_TEST_TMPDIR/scripts"
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' 'echo ok' > "$BATS_TEST_TMPDIR/scripts/check-fake.sh"
  run bash "$ROOT/scripts/check-locale-collation.sh" "$BATS_TEST_TMPDIR/scripts/check-fake.sh"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "guard_init"
}

@test "lane D: guard_init in a comment alone is still red (the lane demands a call, not a mention)" {
  # 리뷰 실측(11): 모든 가드 머리에 "프롤로그는 guard_init(…)이 소유한다" 주석을 심었으므로,
  # 언급만으로 통과하면 호출 줄을 지워도 레인 D가 초록이다 — 주석 스트립 후 행두 호출만 센다.
  mkdir -p "$BATS_TEST_TMPDIR/scripts"
  printf '%s\n' '#!/usr/bin/env bash' '# 프롤로그는 guard_init(scripts/lib/guard.sh)이 소유한다.' 'echo ok' \
    > "$BATS_TEST_TMPDIR/scripts/check-commentonly.sh"
  run bash "$ROOT/scripts/check-locale-collation.sh" "$BATS_TEST_TMPDIR/scripts/check-commentonly.sh"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "guard_init"
}

@test "lane D: a guard that calls guard_init passes, and non-guard scripts are out of scope" {
  mkdir -p "$BATS_TEST_TMPDIR/scripts"
  printf '%s\n' '#!/usr/bin/env bash' '. lib/guard.sh' 'guard_init check-fake' > "$BATS_TEST_TMPDIR/scripts/check-fake2.sh"
  run bash "$ROOT/scripts/check-locale-collation.sh" "$BATS_TEST_TMPDIR/scripts/check-fake2.sh"
  [ "$status" -eq 0 ]
  # 가드 모양이 아닌 스크립트(부트스트랩류)는 레인 D 대상 밖이다.
  printf '%s\n' '#!/usr/bin/env bash' 'echo tool' > "$BATS_TEST_TMPDIR/scripts/run-something.sh"
  run bash "$ROOT/scripts/check-locale-collation.sh" "$BATS_TEST_TMPDIR/scripts/run-something.sh"
  [ "$status" -eq 0 ]
}

@test "a comment quoting a heredoc marker does not blind the detector to the rest of the file" {
  # docs/traps-detail.md 「heredoc 상태 기계가 주석 규칙보다 먼저 돌면 …」 — 상태 기계가 주석 규칙보다 **먼저** 돌면, 인용된 heredoc
  # 표기 한 줄이 파일의 나머지를 통째로 지운다. 착지 전 실측: 이 도메인에서 10파일 2,956줄이
  # 그렇게 투명했고 그중엔 그 함정을 문서화한 회귀 픽스처 자신도 있었다.
  hd="$(heredoc_marker)"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    "# 예전엔 python3 - ${hd}PY 로 했다" \
    'x="$(printf a | sort -u)"' > "$FX/cmt-heredoc.sh"
  run bash "$S" "$FX/cmt-heredoc.sh"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF '[A]'
}

@test "a TS shift-like token in a string does not blind the detector (TS has no heredoc syntax)" {
  # 실측 유발원: tools/ensure-bump-pr.ts의 봇 이메일 문구가 `id`를 delimiter로 오인시켜 그 파일
  # 756줄을 검출기에게서 가렸다. TS/MTS엔 heredoc 문법이 없으므로 표면 종류로 상태 기계를 끈다.
  hd="$(heredoc_marker)"
  printf '%s\n' \
    "const msg = 'author=bot ${hd}id>+bot@users.noreply.github.com>';" \
    'const x = a.localeCompare(b);' > "$FX/tpl.ts"
  run bash "$S" "$FX/tpl.ts"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF '[C]'
}

@test "a real heredoc body is still suppressed and its terminator is still reached" {
  # 음성 대조 — 주석 규칙을 상태 기계 **위로** 올린 수정이 상태 기계 자체를 없앤 것이 아님을 고정한다.
  # 형제 함정 「면제 판정이 주석보다 먼저 돌면 …」이 이 짝을 처방한다: 대조군이 없으면 수정이
  # 억제 자체를 지웠는지 알 수 없다.
  # 본문에 `#` 줄을 넣어 **종료 판정이 여전히 도달함**도 함께 실증한다 — 이 가드는 주석 규칙이
  # 닫힘 판정보다 앞이라, delimiter가 `#`로 시작할 수 없다는 사실에 기대고 있다.
  # 위반이 정확히 1건(종료줄 **뒤**의 것)이어야 둘 다 증명된다.
  hd="$(heredoc_marker)"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    "cat ${hd}EOF" \
    '# 본문의 주석 줄 — 이 줄 때문에 종료 판정이 막히면 안 된다' \
    '  suppressed="$(printf a | sort -u)"' \
    'EOF' \
    'after="$(printf b | sort -u)"' > "$FX/realhd.sh"
  run bash "$S" "$FX/realhd.sh"
  [ "$status" -ne 0 ]
  [ "$(echo "$output" | grep -cF '[A]')" -eq 1 ]
}

@test "a herestring is not read as a heredoc opener (misreading #1 of the trap's enumeration)" {
  # docs/traps-detail.md 「heredoc 상태 기계가 주석 규칙보다 먼저 돌면 …」의 오인원 열거 1번.
  # `match()`가 **2번째** `<`부터 `<< "foo"`로 읽어 delim을 세우면 파일의 나머지가 투명해진다.
  # 이 레포는 `done <<< "$x"` 스타일을 쓰므로 잠복이 아니라 다음 편집 한 줄이 깨우는 형태다.
  # 형제 check-host-ports.sh는 이미 이 관용구를 갖는다 — 처방이 한 소비자에 갇혀 있었다.
  hd="$(heredoc_marker)"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    "grep -q x ${hd}<payload" \
    'x="$(printf a | sort -u)"' > "$FX/hs.sh"
  run bash "$S" "$FX/hs.sh"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF '[A]'
}

@test "an arithmetic left shift is not read as a heredoc opener (misreading #2)" {
  # 오인원 열거 2번 — `$(( a << b ))`의 `<<`도 heredoc이 아니다.
  # ⚠️ 표기를 런타임에 조립하는 이유가 여기서 한 번 더 산다: 리터럴로 적으면 이 처방이 착지하기
  #    **전까지** 이 테스트 파일 자신이 검출기에게 부분적으로 투명해진다.
  hd="$(heredoc_marker)"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    "n=\$(( a ${hd} b ))" \
    'x="$(printf a | sort -u)"' > "$FX/shift.sh"
  run bash "$S" "$FX/shift.sh"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF '[A]'
}

@test "a dead detector emits no marker (a run that could not scan must not claim it did)" {
  # 마커는 "열거·바닥값을 통과했다"는 뜻인데, 검출기가 죽은 실행은 **아무것도 검사하지 못했다**.
  # 그런 실행이 "N건 검사했다"를 내면 소비자가 정반대로 읽는다 — 형제 후행 가드(check-floor-vocab ·
  # check-scan-producers)는 이미 안 낸다. 검출기가 fatal을 내는 결정적 경로(읽을 수 없는 인자)를 쓴다.
  run bash "$S" "$FX/does-not-exist.sh"
  [ "$status" -ne 0 ]
  out="$output"
  run grep -q '^SCAN: check-locale-collation:' <<<"$out"
  [ "$status" -ne 0 ]
}
