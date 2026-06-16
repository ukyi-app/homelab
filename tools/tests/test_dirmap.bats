#!/usr/bin/env bats
# 디렉토리 지도 드리프트 가드 — README.md/AGENTS.md의 platform 지도가 실제 컴포넌트와 정합하는지.
# 새 platform 컴포넌트가 생겼는데 지도를 안 고치면(또는 가상명만 있으면) 게이트가 시끄럽게 실패.
# bash 3.2: 단언은 [ ]/grep만.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "README platform map lists every real platform component" {
  for c in $(ls -d platform/*/ | xargs -n1 basename | grep -vE '^(charts)$'); do
    grep -q "$c" README.md || { echo "missing in README: $c"; return 1; }
  done
}
