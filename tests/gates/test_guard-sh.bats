#!/usr/bin/env bats
# 셸 가드 프롤로그/방출 커널(scripts/lib/guard.sh, lib-convergence d2)의 계약 테스트.
# 3함수: guard_init(프롤로그 — pipefail·LC_ALL=C·ROOT·scan-floor source) ·
# guard_skip(SKIP 마커 + exit 4 원자 방출) · detect_run(awk 검출기의 fail-closed 실행 —
# 인자 검증·rc 포착·READFILES 열거수 대조. #525가 클래스를 명명하고도 #532에서 손 복사로
# 재발한 22줄×3 처방의 lib 수렴).
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과. @test 이름은 영어(CJK 함정).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  LIB="$ROOT/scripts/lib/guard.sh"
}

@test "guard_init exports C collation, resolves ROOT, and loads the scan-floor kernel" {
  run bash -c '. "$1"; guard_init demo; echo "LC=$LC_ALL"; echo "ROOT=$ROOT"; type scan_floor >/dev/null && echo kernel-ok' _ "$LIB"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^LC=C$'
  echo "$output" | grep -q "^ROOT=$ROOT\$"
  echo "$output" | grep -q '^kernel-ok$'
}

@test "guard_init arms errexit so a failing midline command kills the guard" {
  run bash -c '. "$1"; guard_init demo; false; echo alive' _ "$LIB"
  [ "$status" -ne 0 ]
  out="$output"
  run grep -q 'alive' <<<"$out"
  [ "$status" -ne 0 ]
}

@test "guard_skip emits the marker and exit 4 atomically" {
  run bash -c '. "$1"; guard_skip demo-guard "도메인 부재 — 평가하지 않음"' _ "$LIB"
  [ "$status" -eq 4 ]
  echo "$output" | grep -q '^SKIP: demo-guard: 도메인 부재 — 평가하지 않음$'
}

@test "detect_run returns the findings and passes non-READFILES stderr through" {
  f1="$BATS_TEST_TMPDIR/a.txt"; printf 'hit\nmiss\n' > "$f1"
  run bash -c '
    . "$1"
    prog="/hit/ { print FILENAME\": found\" } { nfiles_seen[FILENAME]=1; print \"diag\" > \"/dev/stderr\" }
      END { n=0; for (k in nfiles_seen) n++; printf \"READFILES=%d\\n\", n > \"/dev/stderr\" }"
    findings="$(detect_run demo-label "$prog" "$2")"
    printf "%s\n" "$findings"
  ' _ "$LIB" "$f1"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'a.txt: found'
  echo "$output" | grep -q 'diag'
}

@test "detect_run fails loud when the detector itself dies (the fail-open this kernel closes)" {
  f1="$BATS_TEST_TMPDIR/a.txt"; printf 'x\n' > "$f1"
  run bash -c '. "$1"; detect_run demo-label "this is not awk((" "$2"' _ "$LIB" "$f1"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '검출기가 실패했다'
}

@test "detect_run fails loud when the detector does not report READFILES" {
  f1="$BATS_TEST_TMPDIR/a.txt"; printf 'x\n' > "$f1"
  run bash -c '. "$1"; detect_run demo-label "{ next }" "$2"' _ "$LIB" "$f1"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'READFILES 부재'
}

@test "detect_run fails loud when the read count disagrees with the enumeration" {
  f1="$BATS_TEST_TMPDIR/a.txt"; printf 'x\n' > "$f1"
  f2="$BATS_TEST_TMPDIR/b.txt"; printf 'x\n' > "$f2"
  run bash -c '
    . "$1"
    prog="END { printf \"READFILES=%d\\n\", 1 > \"/dev/stderr\" }"
    detect_run demo-label "$prog" "$2" "$3"
  ' _ "$LIB" "$f1" "$f2"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '스캔이 중간에 무너졌다'
}

@test "detect_run rejects an unreadable target before running the detector" {
  run bash -c '. "$1"; detect_run demo-label "{ next }" "$2/does-not-exist"' _ "$LIB" "$BATS_TEST_TMPDIR"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '읽을 수 없는 대상'
}

@test "detect_run refuses an empty file list instead of reading stdin (red, not a hang)" {
  # 인자 0건이면 awk가 stdin을 읽는다 — bats 스텁 hang과 같은 클래스의 정지를 fail-loud로 바꾼다.
  run bash -c '. "$1"; detect_run demo-label "{ next }" < /dev/null' _ "$LIB"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '검사 대상 0건'
}


@test "every heredoc state machine carries the misreading idioms and sees comments before the opener" {
  # **형태 대조**다 — 정확성이 아니라 동일성. 문구는 바꿔 쓸 수 있지만 awk 토큰은 못 바꾼다.
  # (a) 알려진 오인원 마스킹 관용구를 함께 갖는다: `<<<` herestring · `$(( a << b ))` 좌시프트.
  # (b) 주석 인식이 heredoc **시작** 판정보다 앞선다.
  #     ⚠️ 그 자리가 상태 기계 안인지 밖인지는 **가드의 구조가 정한다** — 오늘 세 소비자가 두
  #        형태로 갈리고 둘 다 옳다(docs/traps-detail.md 「heredoc 상태 기계가 …」의 개정된 일반형).
  # ⚠️ 산문 주석을 배제한다 — 이 레포의 가드 헤더는 자기가 고친 함정을 **인용하며 설명**하므로,
  #    배제하지 않으면 헤더의 인용이 규칙으로 오인돼 대조가 항진명제가 된다(실측: host-ports 헤더).
  run bash -c '
    set -euo pipefail
    n=0
    for f in "$1"/scripts/check-*.sh "$1"/scripts/verify-*.sh; do
      grep -q "inhere" "$f" || continue
      n=$((n+1))
      grep -qF "@HERESTRING@" "$f" || { echo "MISSING-HERESTRING $f"; exit 1; }
      grep -qF "@SHIFT@"      "$f" || { echo "MISSING-SHIFT $f"; exit 1; }
      c=$(awk "\$0 ~ /^[[:space:]]*#/ {next} index(\$0,\"^[ \\\\t]*#\") && index(\$0,\"next\") && !c {c=FNR} END{printf \"%d\", c}" "$f")
      m=$(awk "\$0 ~ /^[[:space:]]*#/ {next} index(\$0,\"match(\") && index(\$0,\"/<<-\") && !m {m=FNR} END{printf \"%d\", m}" "$f")
      [ "$c" -gt 0 ] || { echo "NO-COMMENT-RULE $f"; exit 1; }
      [ "$m" -gt 0 ] || { echo "NO-OPENER-RULE $f"; exit 1; }
      [ "$c" -lt "$m" ] || { echo "COMMENT-AFTER-OPENER $f (주석 ${c}행 >= opener ${m}행)"; exit 1; }
    done
    # 열거 바닥값 — 로스터가 붕괴해 0건을 검사하고 초록이 되는 것을 막는다. 수치는 콜사이트 소유.
    [ "$n" -ge 3 ] || { echo "ROSTER-COLLAPSE n=$n"; exit 1; }
    echo "SHAPE-OK n=$n"
  ' _ "$ROOT"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'SHAPE-OK n='
}

@test "every hand-rolled detector shell declares why the kernel could not serve it" {
  # #532의 재발 형태는 detect_run 처방의 **손 복사**였다. 그 재발을 막으라던 단언이 문구 리터럴
  # 매칭이었던 탓에, 문구를 바꿔 쓴 재구현 2곳이 통째로 빠져나갔다(실측). **문구는 계약이 아니다** —
  # 형태로 대조한다: 검출기 셸을 손으로 여는 자리(프로그램 변수를 awk에 넘기고 stderr를 임시파일로)는
  # 파일이 `detect_run-exempt:` 마커로 **사유를 선언**해야 한다. 선언이 없으면 그것은 부채가 아니라
  # 보이지 않는 부채다.
  run bash -c '
    set -euo pipefail
    roster=0; undeclared=""
    for f in "$1"/scripts/check-*.sh "$1"/scripts/verify-*.sh; do
      hand=0; kern=0
      grep -qE "awk[[:space:]]+\"?\\\$[A-Za-z_]+\"?.*2>\"?\\\$[A-Za-z_]+\"?" "$f" && hand=1
      sed "s|^[[:space:]]*#.*||" "$f" | grep -qE "(^|[|(;&\` ])detect_run[[:space:]]" && kern=1
      [ "$hand" -eq 1 ] || [ "$kern" -eq 1 ] || continue
      roster=$((roster+1))
      if [ "$hand" -eq 1 ]; then
        grep -qF "detect_run-exempt:" "$f" || undeclared="$undeclared $(basename "$f")"
      fi
    done
    [ -z "$undeclared" ] || { echo "UNDECLARED-HANDROLL:$undeclared"; exit 1; }
    # 열거 바닥값 — 로스터가 붕괴하면 위반 0건이 되어 조용히 통과한다. 수치는 콜사이트 소유.
    [ "$roster" -ge 6 ] || { echo "ROSTER-COLLAPSE roster=$roster"; exit 1; }
    echo "DETECTOR-ROSTER=$roster"
  ' _ "$ROOT"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'DETECTOR-ROSTER='
}
