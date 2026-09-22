#!/usr/bin/env bats
# 표준 Bats 게이트가 실제 방화벽 구현의 Python 회귀를 함께 실행한다.
@test "AIOps ingress firewall passes isolated Python regressions" {
  run python3 "$BATS_TEST_DIRNAME/test_aiops_ingress_firewall.py"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}
