#!/usr/bin/env bats
# 오타 옵션 침묵-무시 차단 — create-app/provision-cache의 arg() 헬퍼는 미지정 플래그를
# 조용히 무시해 디폴트를 적용했다(예: --nam을 오타하면 --name이 무시되고 디폴트). allowed-set 거부로
# 오타를 즉시 비-0 종료시킨다. (전체 cli.ts 통합 아님 — 침묵버그 슬라이스만.)
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "create-app rejects an unknown flag" {
  run bun tools/create-app.ts --dry-run --bogus-flag x
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "알 수 없는 옵션"
}

@test "provision-cache rejects an unknown flag" {
  run bun tools/provision-cache.ts --dry-run --bogus-flag x
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "알 수 없는 옵션"
}

@test "teardown-app rejects an unknown flag" {
  run bun tools/teardown-app.ts --app blog --dry-run --bogus-flag x
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "알 수 없는 옵션"
}

@test "teardown-resource rejects an unknown flag" {
  run bun tools/teardown-resource.ts --db shared --dry-run --bogus-flag x
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "알 수 없는 옵션"
}
