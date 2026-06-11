#!/usr/bin/env bats
# 라이브 테스트: 동작 중인 클러스터 + helm + M0 클러스터 age 키가 필요하다.
# 라이브 bootstrap 인수(Task 2.12) 중에만 실행하고, 오프라인 CI에서는 돌리지 않는다.

@test "make bootstrap is idempotent (second run is a no-op)" {
  run make bootstrap
  [ "$status" -eq 0 ]
  run make bootstrap
  [ "$status" -eq 0 ]
  [[ "$output" == *"unchanged"* || "$output" == *"already"* ]]
}
