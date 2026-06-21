#!/usr/bin/env bats
# 런북 인덱스 가드: 로컬 전용·런북 부재 시 clean skip. ⚠️ 중간 단언 [ ]만.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; }

@test "runbook-index guard exists, is local-only, and skips cleanly when runbooks absent" {
  S="$ROOT/scripts/verify-runbook-index.sh"
  [ -f "$S" ]
  run grep -Eq 'docs/runbooks|AGENTS.md' "$S"; [ "$status" -eq 0 ]
  run bash "$S"; [ "$status" -eq 0 ]   # 런북 부재(CI/repo)면 skip(exit 0). bash 호출=exec비트 무의존(F3)
}

@test "existing verify-runbooks DR bats runner target is preserved (not replaced, F2)" {
  run grep -Eq 'bats docs/runbooks' "$ROOT/Makefile"; [ "$status" -eq 0 ]
}
