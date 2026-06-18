#!/usr/bin/env bats
# 셰뱅/exec 비트 정책 가드:
#   - tools/*.ts·*.mts·lib/*.ts는 항상 `bun tools/x.ts`로 호출(exec 비트 없음) → 셰뱅은 dead marker라 금지.
#   - scripts/*.sh는 전부 exec 비트(직접실행/소스 무관 — 일관 정책).
# bash 3.2: 단언은 [ ]만, @test 이름은 영어(한글 인코딩 깨짐 함정).
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "no tools/*.ts/.mts carries a shebang (always invoked via bun — dead marker removed)" {
  bad=""
  for f in $(git ls-files 'tools/*.ts' 'tools/*.mts' 'tools/lib/*.ts'); do
    head -1 "$f" | grep -q '^#!' && bad="$bad $f"
  done
  [ -z "$bad" ]
}

@test "every scripts/*.sh has the executable bit (uniform policy)" {
  bad=""
  for f in $(git ls-files 'scripts/*.sh'); do
    mode=$(git ls-files -s "$f" | awk '{print $1}')
    [ "$mode" = "100755" ] || bad="$bad $f"
  done
  [ -z "$bad" ]
}
