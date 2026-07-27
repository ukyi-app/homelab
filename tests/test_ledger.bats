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

# 드리프트가 전면적일 필요는 없다 — 대문자/신규 문자를 쓴 컴포넌트명 하나가 행 클래스에서 빠지면
# 예산이 과소 합산돼 fail-open이 된다. 바닥값은 그 부분 붕괴도 잡는다.
@test "a partially parsed ledger is rejected too (drift need not be total)" {
  awk '/ledger:row/ { n++; if (n > 8) next } { print }' docs/memory-ledger.md > /tmp/partial-ledger.md
  bun tools/ledger-to-json.ts /tmp/partial-ledger.md > /tmp/partial.json
  run conftest test /tmp/partial.json --policy policy/ledger.rego
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'scan-floor'
}
