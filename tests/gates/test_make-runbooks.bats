#!/usr/bin/env bats
# verify-runbooks — gitignored 로컬 런북(docs/runbooks/*.bats)을 돌리는 진입점.
# restore.md(DR R1) 같은 런북 회귀는 CI 게이트 밖이라(런북 untracked) 로컬에서만 가능 →
# 적어도 단일 명령으로 노출한다. 런북 부재는 **안전 통과가 아니라 SKIP 신호**다(exit 4 + 마커) —
# 그 두 갈래의 행동 단언은 tests/gates/test_guard-skip-signalling.bats가 소유한다.
# 여기 남는 계약은 배선이다: 타깃이 실제로 런북 디렉토리의 bats를 돌리는가.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "verify-runbooks target runs bats over the runbook directory" {
  run make -n verify-runbooks
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE 'bats [^;|]*docs/runbooks'
}

# skip/평가 두 갈래의 단언은 여기 두지 않는다 — tests/gates/test_guard-skip-signalling.bats가 소유하고
# (행동), scripts/check-skip-signalling.sh가 마커↔종료코드 짝을 정적으로 강제한다. 같은 사실을 세 곳에서
# 주장하면 어느 것이 계약인지 흐려진다.
