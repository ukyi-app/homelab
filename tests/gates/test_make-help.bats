#!/usr/bin/env bats
# make help 가독성 — 타겟이 정렬돼 나오는지(타겟이 늘면서 파일순 나열은 스캔이 어렵다).
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "make help lists targets in sorted order" {
  run make help
  [ "$status" -eq 0 ]
  names="$(echo "$output" | awk '{print $1}' | grep -E '^[a-zA-Z]')"
  [ -n "$names" ]
  [ "$names" = "$(echo "$names" | sort)" ]
}
