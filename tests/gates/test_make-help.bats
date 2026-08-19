#!/usr/bin/env bats
# make help 가독성 — 타겟이 정렬돼 나오는지(타겟이 늘면서 파일순 나열은 스캔이 어렵다).
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "make help lists targets in sorted order" {
  # ⚠️ `--no-print-directory`가 계약이다. `make ci`가 이 bats를 부르면 MAKEFLAGS에 `w`가 실려
  #    서브-make가 `make: Entering directory '...'`를 **첫 줄로** 찍고, 아래 `awk '{print $1}'`가
  #    그 `make:`를 타깃 이름으로 집어 정렬이 깨진다(`m` > `a`). 단독 실행에서는 안 나오므로
  #    "혼자 돌리면 초록, make ci에서만 빨강"이 된다.
  #    맥(GNU Make 3.81)에서는 안 밟혔고 NUC(4.4.1)에서 발각됐다 — 2026-08-19 이관.
  run make --no-print-directory help
  [ "$status" -eq 0 ]
  names="$(echo "$output" | awk '{print $1}' | grep -E '^[a-zA-Z]')"
  [ -n "$names" ]
  [ "$names" = "$(echo "$names" | sort)" ]
}
