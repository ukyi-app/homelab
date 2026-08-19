#!/usr/bin/env bats
# CJK @test 이름 가드 — 한글/CJK는 bats 디렉토리 실행 시 침묵스킵(검증된 함정).
# em-dash·trailing 한국어 주석은 bats OK라 제외 — @test "이름"의 **이름만** 검사. ⚠️ 중간 단언 [ ]만.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

# CJK = Unicode 스크립트 속성(무브래킷 fragment — [$CJK]로 1회 감쌈). Han/Hangul/Hiragana/Katakana는
# Ext-A(㐀 U+3400)·compat 이데오그래프·Hangul 확장까지 모두 포함(하드코딩 범위 누락 방지, F7).
CJK='\p{Han}\p{Hangul}\p{Hiragana}\p{Katakana}'
CJK_FIX="tests/gates/test_zzz_cjk_neg_fixture.bats"   # black-box 음성 픽스처(teardown이 정리)
teardown() { git reset -q -- "$CJK_FIX" 2>/dev/null || true; rm -f "$CJK_FIX"; }

@test "CJK detector flags Hangul AND CJK-extension @test NAMES only (script properties; ignores em-dash/ascii/comment)" {
  TMP="$(mktemp -d)"
  printf '  @test "%s" {\n  @test "%s extA" {\n  @test "ascii name" { # %s\n  @test "drill %s PVC" {\n  # @test "%s" mention\n' \
    "한글 이름" "㐀" "한글 주석" "—" "한글" > "$TMP/test_fx.bats"
  # 이름만 캡처 후 $1 검사(F2) — trailing 주석·em-dash·주석언급 제외. 한글(1)+Ext-A 㐀(2)만 HIT.
  run perl -CSDA -ne 'print "$ARGV:$.\n" if /^\s*\@test\s+"([^"]*)"/ && $1 =~ /['"$CJK"']/' "$TMP/test_fx.bats"
  [ "$status" -eq 0 ]
  # ⚠️ `grep -c .`(모든 줄)이 아니라 **결과 형태(`파일:행번호`)에 맞는 줄만** 센다. bats의 `run`은
  #    stderr를 $output에 합치는데, perl은 로케일이 불완전하면 경고를 19줄쯤 쏟는다
  #    (맥에서 ssh할 때 `LC_CTYPE=UTF-8`이 전달되면 리눅스엔 그런 로케일이 없어 그렇게 된다 —
  #     2026-08-19 NUC 이관에서 실측). 그러면 잡음이 카운트에 섞여 이 가드가 **환경 탓으로** 빨개진다.
  #    형태를 특정해도 fail-loud는 유지된다: perl이 진짜로 죽으면 매칭 줄이 0이라 여전히 실패한다.
  [ "$(printf '%s' "$output" | grep -cE ':[0-9]+$')" -eq 2 ]   # 정확히 2줄(한글·㐀 이름 선언)
  echo "$output" | grep -q ':1$'                      # 한글(라인1)
  echo "$output" | grep -q ':2$'                      # Ext-A 㐀(라인2) — 하드코딩 범위면 놓침
}

@test "check-skeleton FAILS (exit!=0) on a tracked CJK @test name — black-box negative (F5)" {
  # 토큰 grep이 아니라 실제 실행: CJK @test 픽스처를 git ls-files에 보이게(add -N) 한 뒤 check-skeleton 실행.
  printf '@test "%s" {\n  true\n}\n' "한글이름테스트" > "$CJK_FIX"
  git add -N "$CJK_FIX"
  run bash scripts/check-skeleton.sh
  [ "$status" -ne 0 ]                                     # CJK @test 때문에 비-0 종료(rc=1 배선 증명)
  echo "$output" | grep -q 'CJK'                          # CJK 메시지로 실패(다른 이유 아님)
}

@test "current repo has zero CJK @test names (immediate-green)" {
  bad=""
  while IFS= read -r f; do
    h="$(perl -CSDA -ne 'print "x" if /^\s*\@test\s+"([^"]*)"/ && $1 =~ /['"$CJK"']/' "$f")"
    if [ -n "$h" ]; then bad="$bad $f"; fi
  done < <(git ls-files '*test_*.bats')
  [ -z "$bad" ]
}
