#!/usr/bin/env bats
# bats 단언-스타일 가드의 gate 테스트 — 탐지기가 스스로 vacuous하지 않음을 fixture로 증명(선례: test_bats-naming.bats).
# ⚠️ 중간 단언은 [ ]만(bash 3.2 [[ ]] 침묵 통과 — 이 파일이 막으려는 바로 그 함정).
# ⚠️ **피연산자 실재 증인**(형제 tests/gates/test_host-ports.bats:57-58 · test_locale-collation.bats:15).
#    `run bash "$ROOT/scripts/check-bats-style.sh" …`는 가드가 없으면 rc **127**로 죽어 `-ne 0` 레인을
#    통과시키고, 돌지 않은 프로그램은 마커도 안 내 부재 단언까지 함께 만족시킨다. 실측 2026-09-03
#    (가드를 지운 트리): 23건 중 「a dead detector emits no marker」 1건만 그대로 `ok`였다.
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  [ -f "$ROOT/scripts/check-bats-style.sh" ]
  # heredoc 여는 표기는 lib이 런타임에 조립한다 — 리터럴로 적으면 이 파일이 검출기에게 투명해진다.
  # shellcheck source=tests/gates/lib/heredoc-marker.sh
  . "$ROOT/tests/gates/lib/heredoc-marker.sh"
}

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

# 도메인(추적 `*.bats` + `load` seam `*.bash`)이 비면 통과가 아니라 SKIP이다 — 수집이 깨져 0건이 된
# 것과 "검사했고 깨끗함"을 가르지 못하면 이 가드가 죽어도 게이트가 초록이다.
# ⚠️ 채널은 **skip이 아니라 열거 붕괴**다 — 기본 모드 도메인은 정당하게 0이 될 수
# 없다. (건수는 여기 적지 않는다 — 손 관리 수치는 드리프트한다, scripts/lib/scan-floor.sh 규약.
# 착지 전 주석에 남아 있던 "229건"은 실제 열거와 어긋난 낡은 수치였다.)
# 거의 같은 도메인의 형제(check-skeleton·check-bats-accounting — `*.bats`만)가 exit 1 바닥값이라,
# 여기서 exit 4 + `SKIP:`를 내면 "정당하게 대상 없음(미평가·정상)"으로 정반대로 읽힌다(적대 검토 확정).
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

# 경로 규약 증인 — **bats 도메인 = 추적 `*.bats` + bats가 `load`하는 `*.bash` seam**
# (근거·경계는 check-bats-style.sh의 열거 주석이 소유한다). `.bash`는 `git ls-files '*.bats'`
# 단독 열거에 **안 보이므로**, 글롭이 그리로 되돌아가면 그 seam은 이 가드에게 영원히 투명해진다 —
# 주석만으로는 그 회귀에 아무도 red를 내지 않는다. 픽스처는 형제 '열거 붕괴' 테스트와 같은 관용구다.
@test "the default domain covers the *.bash seams bats loads, not just *.bats" {
  FIX="$BATS_TEST_TMPDIR/seamrepo"
  mkdir -p "$FIX/scripts/lib" "$FIX/tests"
  cp "$ROOT/scripts/check-bats-style.sh" "$FIX/scripts/"
  cp "$ROOT/scripts/lib/scan-floor.sh" "$ROOT/scripts/lib/guard.sh" "$FIX/scripts/lib/"
  printf '%s\n' '@test "noop" {' '  [ 1 -eq 1 ]' '}' > "$FIX/tests/test_x.bats"
  printf '%s\n' 'helper_fn() { :; }' > "$FIX/tests/test_helper.bash"
  git -C "$FIX" init -q
  git -C "$FIX" add -A
  # 바닥값은 실 레포 크기라 픽스처에선 공용 어휘 `--floor`로 낮춘다(구 env 오버라이드는 폐지).
  run bash "$FIX/scripts/check-bats-style.sh" --floor check-bats-style=1
  [ "$status" -eq 0 ]
  # 2 = .bats 1건 + .bash 1건. 글롭이 `*.bats` 단독으로 좁아지면 1이 되어 여기서 red가 난다.
  echo "$output" | grep -qxF 'SCAN: check-bats-style: 2'
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
  # 인용된 heredoc 표기 한 줄이 @test의 나머지를 통째로 지운다
  # (docs/traps-detail.md 「heredoc 상태 기계가 주석 규칙보다 먼저 돌면 …」).
  # 이 파일 도메인(*.bats)에서 착지 전 실측 5파일 602줄이 그렇게 투명했다.
  hd="$(heredoc_marker)"
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

@test "a real heredoc body is still suppressed and its terminator is still reached" {
  # 음성 대조 — 주석 스킵을 heredoc 매치 앞에 넣은 수정이 상태 기계 자체를 없앤 것이 아님을 고정한다.
  # 이 가드는 주석 스킵이 `inhere` **닫힘 판정 뒤**라 종료 판정이 본문 주석에 가리지 않는다.
  # 위반이 정확히 1건(종료줄 **뒤**의 것)이어야 억제와 종료가 둘 다 증명된다.
  hd="$(heredoc_marker)"
  printf '%s\n' \
    '@test "real heredoc body" {' \
    "  cat ${hd}EOF" \
    '# 본문의 주석 줄' \
    '  ! echo suppressed | grep -q zzz' \
    'EOF' \
    '  run echo hi' \
    '  ! echo "$output" | grep -q zzz' \
    '  [ "$status" -eq 0 ]' \
    '}' > "$BATS_TEST_TMPDIR/test_realhd.bats"
  run bash "$ROOT/scripts/check-bats-style.sh" "$BATS_TEST_TMPDIR/test_realhd.bats"
  [ "$status" -ne 0 ]
  [ "$(echo "$output" | grep -cF '[NEG]')" -eq 1 ]
}

@test "a herestring is not read as a heredoc opener (misreading #1)" {
  # 형제 check-locale-collation·check-host-ports와 같은 오인원. 이 레포는 `done <<< "$x"`를 쓴다.
  hd="$(heredoc_marker)"
  printf '%s\n' \
    '@test "herestring in a test body" {' \
    "  grep -q x ${hd}<payload" \
    '  ! echo hi | grep -q zzz' \
    '  [ 1 -eq 1 ]' \
    '}' > "$BATS_TEST_TMPDIR/test_hs.bats"
  run bash "$ROOT/scripts/check-bats-style.sh" "$BATS_TEST_TMPDIR/test_hs.bats"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '\[NEG\]'
}

@test "an arithmetic left shift is not read as a heredoc opener (misreading #2)" {
  hd="$(heredoc_marker)"
  printf '%s\n' \
    '@test "shift in a test body" {' \
    "  n=\$(( a ${hd} b ))" \
    '  ! echo hi | grep -q zzz' \
    '  [ 1 -eq 1 ]' \
    '}' > "$BATS_TEST_TMPDIR/test_shift.bats"
  run bash "$ROOT/scripts/check-bats-style.sh" "$BATS_TEST_TMPDIR/test_shift.bats"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '\[NEG\]'
}

@test "a dead detector emits no marker (a run that could not scan must not claim it did)" {
  # 형제 check-locale-collation·check-host-ports와 같은 규율 — 검출기가 죽은 실행은
  # 아무것도 검사하지 못했으므로 "N건 검사했다"를 내면 안 된다.
  run bash "$ROOT/scripts/check-bats-style.sh" "$BATS_TEST_TMPDIR/does-not-exist.bats"
  [ "$status" -ne 0 ]
  out="$output"
  # ★ **양성 대조 — 가드가 실제로 돌아서 거부했다.** setup의 `[ -f ]`가 못 보는 경로(가드가
  #   실재하면서 판정 전에 다른 이유로 크래시)까지 여기서 증언한다 — 자기 진단 문구를 함께 물어
  #   "죽은 검출기"와 "없는 검출기"를 갈라낸다(guard.sh detect_run의 읽기 검증 경로 · 문구 드리프트는 red).
  printf '%s' "$out" | grep -qF '읽을 수 없는 대상'
  run grep -q '^SCAN: check-bats-style:' <<<"$out"
  [ "$status" -ne 0 ]
}

# ── [ABS] 레인 — bats 부재 단언(철자 + 형태) ──────────────────────────────────────────────────
# 근거·분모 규약은 scripts/check-bats-style.sh 헤더가 소유한다. 여기 증인이 재는 것은 셋이다:
#   ⓐ 옛 철자(`-ne 0`)가 red다 · ⓑ 정당한 비대상(히어스트링)이 red가 **아니다** ·
#   ⓒ 형태 요구가 **접속사**다 — 증인 둘 중 하나만 있으면 red(01~04가 손으로 건 setup 단언이
#     영구 가드에게 보이지 않던 자리를 닫는 것이 이 클래스의 존재 이유다).
# 픽스처는 printf로 만든다(bats 전처리기가 .bats 소스의 heredoc 속 '@test'를 재작성한다 — 위 주석 참조).

@test "detector rejects the stale absence spelling (-ne 0 on a grep with a path operand)" {
  printf '%s\n' \
    '@test "stale absence spelling" {' \
    '  run grep -q TOKEN some/file' \
    '  [ "$status" -ne 0 ]' \
    '}' > "$BATS_TEST_TMPDIR/test_abs_stale.bats"
  run bash "$ROOT/scripts/check-bats-style.sh" "$BATS_TEST_TMPDIR/test_abs_stale.bats"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '\[ABS\]'
}

@test "a herestring absence assertion is NOT a finding (the denominator excludes it)" {
  # ⚠️ 이 구별이 이 가드 설계의 첫 제약이다 — 착지 시점 잔여 `-ne 0`은 95곳이고 **전부**
  #    히어스트링이었다(그 중 tests/gates/test_scan-floor.bats 18곳). 히어스트링은 경로
  #    피연산자가 없어 rc 2 채널 자체가 없으므로 그 자리의 `-ne 0`은 옳다. 분모에 넣으면
  #    그 파일이 영구 red 또는 영구 예외 목록 항목이 된다.
  printf '%s\n' \
    '@test "herestring absence" {' \
    '  run grep -qF -- TOKEN <<<"$out"' \
    '  [ "$status" -ne 0 ]' \
    '}' > "$BATS_TEST_TMPDIR/test_abs_hs.bats"
  run bash "$ROOT/scripts/check-bats-style.sh" "$BATS_TEST_TMPDIR/test_abs_hs.bats"
  [ "$status" -eq 0 ]
}

@test "a recursive absence assertion with neither witness is a finding" {
  printf '%s\n' \
    '@test "recursive absence, no witnesses" {' \
    '  run grep -rn TOKEN "$TREE"' \
    '  [ "$status" -eq 1 ]' \
    '}' > "$BATS_TEST_TMPDIR/test_abs_rec0.bats"
  run bash "$ROOT/scripts/check-bats-style.sh" "$BATS_TEST_TMPDIR/test_abs_rec0.bats"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '\[ABS-REC\]'
}

@test "the same recursive assertion passes once floor AND positive control are present" {
  # 음성 대조 — 이 레인이 '재귀면 무조건 red'가 아니라 **증인 두 종류의 부재**를 재는지 고정한다.
  # 바닥값은 setup()에 둔다: 파일 수준 스코프가 실제로 증인을 공급하는지도 여기서 함께 잰다
  # (`bats -f`로 @test를 개별 실행해도 setup은 먼저 돈다 — 01번이 별도 @test에서 setup으로
  #  양성 대조를 옮긴 이유와 같다).
  printf '%s\n' \
    'setup() {' \
    '  [ -d "$TREE" ]' \
    '}' \
    '@test "recursive absence, both witnesses" {' \
    '  run grep -rl ANCHOR "$TREE"' \
    '  [ "$status" -eq 0 ]' \
    '  run grep -rn TOKEN "$TREE"' \
    '  [ "$status" -eq 1 ]' \
    '}' > "$BATS_TEST_TMPDIR/test_abs_recok.bats"
  run bash "$ROOT/scripts/check-bats-style.sh" "$BATS_TEST_TMPDIR/test_abs_recok.bats"
  [ "$status" -eq 0 ]
}

@test "deleting the floor from that pair is red (the requirement is a conjunction)" {
  printf '%s\n' \
    '@test "recursive absence, positive control only" {' \
    '  run grep -rl ANCHOR "$TREE"' \
    '  [ "$status" -eq 0 ]' \
    '  run grep -rn TOKEN "$TREE"' \
    '  [ "$status" -eq 1 ]' \
    '}' > "$BATS_TEST_TMPDIR/test_abs_recpos.bats"
  run bash "$ROOT/scripts/check-bats-style.sh" "$BATS_TEST_TMPDIR/test_abs_recpos.bats"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '\[ABS-REC\]'
}

@test "deleting the positive control from that pair is red (the requirement is a conjunction)" {
  printf '%s\n' \
    'setup() {' \
    '  [ -d "$TREE" ]' \
    '}' \
    '@test "recursive absence, floor only" {' \
    '  run grep -rn TOKEN "$TREE"' \
    '  [ "$status" -eq 1 ]' \
    '}' > "$BATS_TEST_TMPDIR/test_abs_recfl.bats"
  run bash "$ROOT/scripts/check-bats-style.sh" "$BATS_TEST_TMPDIR/test_abs_recfl.bats"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '\[ABS-REC\]'
}

@test "a loop-driven absence assertion carries the same requirement" {
  # 루프는 목록이 비면 반복 0회라 **어떤 rc로도** 안 보인다(`for d in $DISPATCHERS` 실측 사례).
  printf '%s\n' \
    '@test "loop-driven absence, no witnesses" {' \
    '  for f in "$WF"/*.yaml; do' \
    '    run grep -q TOKEN "$f"' \
    '    [ "$status" -eq 1 ]' \
    '  done' \
    '}' > "$BATS_TEST_TMPDIR/test_abs_loop.bats"
  run bash "$ROOT/scripts/check-bats-style.sh" "$BATS_TEST_TMPDIR/test_abs_loop.bats"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '\[ABS-LOOP\]'
}

@test "git grep needs the positive control and no filesystem floor (asymmetry is deliberate)" {
  # pathspec은 파일시스템 경로가 아니라 바닥값을 걸 대상이 없고, pathspec이 추적 파일과 하나도
  # 안 맞을 때 git grep은 128이 아니라 **rc 1**이다(실측 git 2.53.0) — 그 붕괴는 같은 pathspec의
  # 양성 대조로만 보인다. 파일시스템 바닥값을 강요하면 실제 구멍을 안 닫는 줄을 세우게 된다.
  printf '%s\n' \
    '@test "git grep absence, no positive control" {' \
    '  run git grep -n TOKEN -- "*.yaml"' \
    '  [ "$status" -eq 1 ]' \
    '}' > "$BATS_TEST_TMPDIR/test_abs_git0.bats"
  run bash "$ROOT/scripts/check-bats-style.sh" "$BATS_TEST_TMPDIR/test_abs_git0.bats"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '\[ABS-GIT\]'
  printf '%s\n' \
    '@test "git grep absence, positive control only" {' \
    '  git grep -q ANCHOR -- "*.yaml"' \
    '  run git grep -n TOKEN -- "*.yaml"' \
    '  [ "$status" -eq 1 ]' \
    '}' > "$BATS_TEST_TMPDIR/test_abs_gitok.bats"
  run bash "$ROOT/scripts/check-bats-style.sh" "$BATS_TEST_TMPDIR/test_abs_gitok.bats"
  [ "$status" -eq 0 ]
}

@test "detector rejects a pipeline-terminal grep -qv (line-wise inversion is not absence)" {
  # ⚠️ 옵션 두 글자를 런타임에 조립한다 — 리터럴로 적으면 이 파일 자신이 [QV] 레인에 걸린다
  #    (같은 처방: tests/gates/lib/heredoc-marker.sh — 고치려는 함정이 테스트를 쓰는 동안 물린다).
  qv="-q""v"
  printf '%s\n' \
    '@test "qv absence" {' \
    "  echo \"\$out\" | grep ${qv}F TOKEN" \
    '  [ 1 -eq 1 ]' \
    '}' > "$BATS_TEST_TMPDIR/test_abs_qv.bats"
  run bash "$ROOT/scripts/check-bats-style.sh" "$BATS_TEST_TMPDIR/test_abs_qv.bats"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '\[QV\]'
}

@test "the state machine reaches 0-column function bodies, not just @test bodies" {
  # 착지 전 검출기는 `^@test … {`로만 상태에 들어가서, 도메인에 있는 파일이어도 setup()·헬퍼
  # 본문은 전부 판정 밖이었다(그 갭을 가드 헤더가 「부재-단언 클래스를 얹을 때의 몫」으로 계상해
  # 뒀다). 이 증인이 그 확장을 고정한다 — `^@test`로 되돌리면 여기서만 red가 난다.
  printf '%s\n' \
    'make_stubs() {' \
    '  run echo hi' \
    '  ! echo "$output" | grep -q zzz' \
    '  [ "$status" -eq 0 ]' \
    '}' > "$BATS_TEST_TMPDIR/test_abs_fn.bats"
  run bash "$ROOT/scripts/check-bats-style.sh" "$BATS_TEST_TMPDIR/test_abs_fn.bats"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '\[NEG\]'
}

@test "the default-mode summary announces the absence-assertion ratchet" {
  # 래칫 판정이 통째로 빠져도 나머지 레인이 초록을 유지하면 아무도 red를 못 낸다 — 잔액 방출을
  # 형태로 고정한다(형제 scan-floor 커널의 `SCAN:` 마커와 같은 규율: 판정했다는 사실이 관측 가능해야 한다).
  run bash "$ROOT/scripts/check-bats-style.sh"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '부재 단언 [0-9]+ \(baseline [0-9]+\)'
}
