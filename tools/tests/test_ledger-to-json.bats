#!/usr/bin/env bats
# ledger-to-json bun 이관 — conftest 입력 JSON 형식 고정(구 awk 출력과 바이트 동일 계약).
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TOOL="$ROOT/tools/ledger-to-json.ts"
  TMP="$(mktemp -d)"
}
teardown() { rm -rf "$TMP"; }

@test "fixture ledger renders the exact legacy JSON shape (snapshot)" {
  cat > "$TMP/ledger.md" <<'EOF'
<!-- ledger:meta VM_ALLOCATABLE_MIB=1024 LIMIT_BUDGET_MIB=512 -->
| <!-- ledger:row --> aaa            | prod           |     10 |       20 |
| <!-- ledger:row --> k3s+os+coredns | kube-system    |     30 |       40 |
EOF
  run bun "$TOOL" "$TMP/ledger.md"
  [ "$status" -eq 0 ]
  [ "$output" = '{"budget":512,"rows":[{"component":"aaa","req":10,"limit":20},{"component":"k3s+os+coredns","req":30,"limit":40}]}' ]
}

@test "row with a digit-bearing namespace is not silently dropped (env class regression)" {
  cat > "$TMP/ledger.md" <<'EOF'
<!-- ledger:meta VM_ALLOCATABLE_MIB=1024 LIMIT_BUDGET_MIB=512 -->
| <!-- ledger:row --> aaa | pg18 | 10 | 20 |
EOF
  run bun "$TOOL" "$TMP/ledger.md"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"component":"aaa"'
}

@test "missing LIMIT_BUDGET_MIB meta fails loud (awk emitted malformed JSON instead)" {
  printf '| <!-- ledger:row --> aaa | prod | 10 | 20 |\n' > "$TMP/ledger.md"
  run bun "$TOOL" "$TMP/ledger.md"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'LIMIT_BUDGET_MIB'
}

@test "real ledger output passes the conftest budget policy end-to-end" {
  cd "$ROOT" || exit 1
  bun tools/ledger-to-json.ts docs/memory-ledger.md > "$TMP/ledger.json"
  run conftest test "$TMP/ledger.json" --policy policy/ledger.rego
  [ "$status" -eq 0 ]
}
