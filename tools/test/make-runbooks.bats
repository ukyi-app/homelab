#!/usr/bin/env bats
# verify-runbooks — gitignored 로컬 런북(docs/runbooks/*.bats)을 돌리는 진입점.
# restore.md(DR R1) 같은 런북 회귀는 CI 게이트 밖이라(런북 untracked) 로컬에서만 가능 →
# 적어도 단일 명령으로 노출하고, 런북 부재(러너/fresh checkout)에선 안전 통과.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "verify-runbooks target exists and is safe when runbooks are absent" {
  run make -n verify-runbooks
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "docs/runbooks"
}
