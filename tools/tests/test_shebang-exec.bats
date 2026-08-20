#!/usr/bin/env bats
# 셰뱅/exec 비트 정책 가드:
#   - tools/*.ts·*.mts·lib/*.ts는 항상 `bun tools/x.ts`로 호출(exec 비트 없음) → 셰뱅은 dead marker라 금지.
#   - **예외 = package.json bin 대상**(SSOT에서 파생 — 하드코딩 목록 금지): bun link가 전역 PATH에
#     심링크하는 진입점이라 셰뱅이 live하고, `#!/usr/bin/env bun` + exec 비트(100755)를 **요구**한다.
#   - scripts/*.sh는 전부 exec 비트(직접실행/소스 무관 — 일관 정책).
# bash 3.2: 단언은 [ ]만, @test 이름은 영어(한글 인코딩 깨짐 함정).
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "no tools/*.ts/.mts carries a shebang except package.json bin entrypoints (which require bun shebang + exec bit)" {
  bins="$(jq -r '.bin // {} | .[]' package.json)"
  bad=""
  nbin=0
  for f in $(git ls-files 'tools/*.ts' 'tools/*.mts' 'tools/lib/*.ts'); do
    is_bin=0
    for b in $bins; do
      if [ "$f" = "$b" ]; then is_bin=1; fi
    done
    if [ "$is_bin" -eq 1 ]; then
      nbin=$((nbin+1))
      if ! head -1 "$f" | grep -q '^#!/usr/bin/env bun$'; then bad="$bad $f(bin인데-bun-셰뱅-부재)"; fi
      mode=$(git ls-files -s "$f" | awk '{print $1}')
      if [ "$mode" != "100755" ]; then bad="$bad $f(bin인데-exec-비트-부재)"; fi
    else
      if head -1 "$f" | grep -q '^#!'; then bad="$bad $f"; fi
    fi
  done
  [ -z "$bad" ]
  # 열거 바닥값: 선언된 bin이 실제로 순회에 잡혔는가(bin 경로 오타 → 예외가 조용히 죽는 것 차단)
  [ "$nbin" -eq "$(jq -r '.bin // {} | length' package.json)" ]
}

@test "every scripts/*.sh has the executable bit (uniform policy)" {
  bad=""
  for f in $(git ls-files 'scripts/*.sh'); do
    mode=$(git ls-files -s "$f" | awk '{print $1}')
    [ "$mode" = "100755" ] || bad="$bad $f"
  done
  [ -z "$bad" ]
}
