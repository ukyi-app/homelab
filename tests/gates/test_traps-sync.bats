#!/usr/bin/env bats
# 트랩 SSOT 동기화 가드: AGENTS 인덱스 ↔ traps-detail.md 헤드라인 + 역방향 guard-path-tie. ⚠️ 중간 단언 [ ]만.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; }

@test "every traps-detail.md heading appears in the AGENTS.md trap index (no drift)" {
  D="$ROOT/docs/traps-detail.md"; A="$ROOT/AGENTS.md"
  # traps-detail '### ' 헤드라인 추출 → 각각 AGENTS 인덱스에 존재(헤드라인 = 인덱스 줄과 동일 텍스트)
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    grep -Fq -- "$h" "$A" || { echo "FAIL: AGENTS 인덱스에 누락된 트랩 헤드라인: $h"; false; }
  done < <(grep '^### ' "$D" | sed 's/^### //')
}

@test "trap index count matches traps-detail section count" {
  A="$ROOT/AGENTS.md"; D="$ROOT/docs/traps-detail.md"
  # AGENTS 트랩 인덱스 불릿 수 == traps-detail '### ' 수
  idx="$(sed -n '/^## 라이브에서 검증된 함정/,/^## /p' "$A" | grep -c '^- ')"
  det="$(grep -c '^### ' "$D")"
  [ "$idx" -eq "$det" ]
}

@test "reverse guard-path-tie passes and excludes prose-mentioned paths (F6)" {
  T="$ROOT/docs/traps.md"; D="$ROOT/docs/traps-detail.md"
  # traps.md prose(표 밖)에 scripts/verify-traps.sh 존재하나 SSOT '> 가드:' 주석이 아니라 tie 비대상
  run grep -Fq 'scripts/verify-traps.sh' "$T"; [ "$status" -eq 0 ]
  run grep -Fq 'scripts/verify-traps.sh' "$D"; [ "$status" -ne 0 ]
  # verify-traps(역방향 tie 포함)가 PASS — SSOT '> 가드:' 주석이 전부 원장에 추적됨
  run bash "$ROOT/scripts/verify-traps.sh"; [ "$status" -eq 0 ]
}
