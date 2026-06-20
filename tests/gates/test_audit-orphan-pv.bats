#!/usr/bin/env bats
# 고아 Released PV 감사 — fail-closed(깨진 감사 ≠ 고아 없음, F7). ⚠️ 중간 단언 [ ]만.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "orphan-PV audit surfaces Released PVs and is fail-closed (broken audit != no orphans)" {
  S="$ROOT/scripts/audit-orphan-pv.sh"
  [ -x "$S" ]
  run grep -Eq 'status\.phase.*Released|"Released"' "$S"; [ "$status" -eq 0 ]      # Released 선택
  run grep -Eq 'command -v kubectl|command -v yq' "$S"; [ "$status" -eq 0 ]        # preflight
  run grep -Eq 'exit [23]' "$S"; [ "$status" -eq 0 ]                               # 실패는 비-0
  # 클러스터 없는 환경(CI)서 실행 → 비-0 + '고아 없음' 미출력(깨진 감사를 깨끗한 결과로 위장 안 함)
  run bash "$S"
  [ "$status" -ne 0 ]
  run grep -q '고아 없음' <<< "$output"
  [ "$status" -ne 0 ]   # 클러스터 부재 출력에 '고아 없음'이 있으면 실패(혼동 방지)
}
