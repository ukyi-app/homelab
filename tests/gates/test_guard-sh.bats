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

@test "the detector prescription lives only in the kernel (hand copies stay dead)" {
  # #532의 재발 형태는 이 처방 22줄의 손 복사였다 — 처방 고유 문구가 lib 밖 scripts/*.sh에
  # 다시 나타나면 red다(lib은 glob 밖이라 자동 제외).
  run grep -l "읽은 파일 수를 보고하지" "$ROOT"/scripts/*.sh
  [ "$status" -ne 0 ]
  grep -q "읽은 파일 수를 보고하지" "$ROOT/scripts/lib/guard.sh"
}
