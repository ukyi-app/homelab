#!/usr/bin/env bats
# 원장 포맷 + verify:ledger 게이트는 M0 소유. 이 스위트는 M6 앱들이 예산 안에 들고,
# 게이트가 예산 초과 원장을 거부하는지를 검증한다. (참고: verify:ledger는 앱 values가
# 아니라 원장 문서를 검증한다; 앱별 메모리 limit 누락은 차트의 values.schema.json
# minLength가 더 먼저 잡는다 — tools/test/schema.bats 참고.)

@test "verify:ledger passes on current apps (M6 rows within budget)" {
  run bun run verify:ledger
  [ "$status" -eq 0 ]
}

@test "verify:ledger FAILS an over-budget ledger (negative test, gate mechanism)" {
  cp docs/memory-ledger.md /tmp/bad-ledger.md
  printf '| <!-- ledger:row --> hog | prod | 100 | 9000 |\n' >> /tmp/bad-ledger.md
  scripts/ledger-to-json.sh /tmp/bad-ledger.md > /tmp/bad.json
  run conftest test /tmp/bad.json --policy policy/ledger.rego
  [ "$status" -ne 0 ]
  [[ "$output" == *"over budget"* ]]
}
