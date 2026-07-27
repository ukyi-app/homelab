#!/usr/bin/env bats

@test "seed ledger passes the budget policy" {
  bun tools/ledger-to-json.ts docs/memory-ledger.md > /tmp/ledger.json
  run conftest test /tmp/ledger.json --policy policy/ledger.rego
  [ "$status" -eq 0 ]
}

@test "over-budget ledger is rejected" {
  cp docs/memory-ledger.md /tmp/bad-ledger.md
  # add a 9000Mi row that blows the 10240 budget (seed total ~9212 + 9000 > 10240)
  printf '| <!-- ledger:row --> hog | prod | 100 | 9000 |\n' >> /tmp/bad-ledger.md
  bun tools/ledger-to-json.ts /tmp/bad-ledger.md > /tmp/bad.json
  run conftest test /tmp/bad.json --policy policy/ledger.rego
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'over budget'
}

# 열거 붕괴 → vacuous green. 예산 deny 2개가 전부 input.rows 한정이라 행이 0이면 **동시에** 무발화한다.
@test "a ledger whose row markers drifted is rejected by the scan-floor, not silently vacuous" {
  sed 's/ledger:row/ledger:ROW/g' docs/memory-ledger.md > /tmp/drift-ledger.md
  bun tools/ledger-to-json.ts /tmp/drift-ledger.md > /tmp/drift.json
  run conftest test /tmp/drift.json --policy policy/ledger.rego
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'scan-floor'
}

# ⚠️ 바닥값(12)은 **전면 붕괴 소관**이다 — 실 17행 대비 1~5행 소실은 못 잡는다(적대 검토 실측:
# 상위 5행이 클래스 밖으로 밀리면 12행/2256Mi가 남아 경계에 걸터앉고 전 게이트가 초록이었다).
# 그 부분 붕괴는 ledger-to-json의 **마커↔파싱 1:1 대조**가 소유한다(아래 @test).
@test "a partially parsed ledger is rejected too (drift need not be total)" {
  awk '/ledger:row/ { n++; if (n > 8) next } { print }' docs/memory-ledger.md > /tmp/partial-ledger.md
  bun tools/ledger-to-json.ts /tmp/partial-ledger.md > /tmp/partial.json
  run conftest test /tmp/partial.json --policy policy/ledger.rego
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'scan-floor'
}

# 부분 드리프트의 실제 형태 — 컴포넌트명 **하나**가 행 클래스 밖 문자로 밀리는 경우.
# 바닥값으로는 못 잡고(17→16은 12 이상), 마커↔파싱 1:1 대조만이 잡는다.
@test "a single row falling out of the row class is rejected (partial drift under-sums the budget)" {
  sed -E 's/(ledger:row --> )observability/\1X_observability/' docs/memory-ledger.md > /tmp/one-row.md
  run bun tools/ledger-to-json.ts /tmp/one-row.md
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '마커'
}
