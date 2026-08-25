#!/usr/bin/env bats
# 정책 원장 리더(tools/lib/policy-ledger.ts, lib-convergence d1 — design r1-4 축소 범위)의 계약 테스트.
# readLedger는 fail-closed 로딩 · 통일 shape({_readme, <container>}) · schema-check 항목 검증까지만
# 소유한다 — 미선언/죽은-선언 대조는 콜사이트 소유(CONTEXT.md 「정책 원장」).
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과. @test 이름은 영어(CJK 함정).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  FX="$BATS_TEST_TMPDIR/r.ts"
  LEDGER="$BATS_TEST_TMPDIR/ledger.json"
  # 픽스처 러너: env로 path/container/entrySchema를 받아 readLedger를 부른다.
  # ⚠️ heredoc은 비인용(EOF) — $ROOT 확장 필요. TS 본문은 ${} 템플릿 리터럴을 쓰지 않는다.
  cat > "$FX" <<EOF
import { readLedger } from "$ROOT/tools/lib/policy-ledger.ts";
try {
  const schema = process.env.PL_SCHEMA ? JSON.parse(process.env.PL_SCHEMA) : undefined;
  const v = readLedger({
    path: process.env.PL_PATH ?? "",
    container: process.env.PL_CONTAINER ?? "entries",
    entrySchema: schema,
    minEntries: process.env.PL_MIN ? Number(process.env.PL_MIN) : undefined,
  });
  const n = Array.isArray(v) ? v.length : Object.keys(v as object).length;
  console.log("LOADED " + n);
} catch (e) {
  console.error("CAUGHT: " + (e instanceof Error ? e.message : String(e)));
  process.exit(1);
}
EOF
}

@test "a missing ledger file fails closed and names the zero-entries disguise" {
  PL_PATH="$BATS_TEST_TMPDIR/does-not-exist.json" run bun "$FX"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "항목 0개"
  echo "$output" | grep -q "does-not-exist.json"
}

@test "unparseable JSON fails closed" {
  printf '{ not json' > "$LEDGER"
  PL_PATH="$LEDGER" run bun "$FX"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "파싱 실패"
}

@test "a ledger without the container key fails closed" {
  printf '{ "_readme": ["x"], "other": [] }' > "$LEDGER"
  PL_PATH="$LEDGER" PL_CONTAINER=entries run bun "$FX"
  [ "$status" -eq 1 ]
}

@test "an empty container below the consumer floor fails closed" {
  # 임계값은 소비자 소유다 — "정당한 0건"(image-ownership의 빈 unowned)과 "붕괴한 0건"의 구별은
  # 도메인 지식이라 커널이 일률로 정하지 않는다(scripts/lib/scan-floor.sh와 같은 규율).
  printf '{ "_readme": ["x"], "entries": [] }' > "$LEDGER"
  PL_MIN=1 PL_PATH="$LEDGER" run bun "$FX"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "항목 0건"
}

@test "an empty container with no floor is legitimate (zero declarations is a valid ledger state)" {
  printf '{ "_readme": ["x"], "entries": [] }' > "$LEDGER"
  PL_PATH="$LEDGER" run bun "$FX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^LOADED 0$'
}

@test "a legacy comment key is rejected (shape unification forces _readme)" {
  printf '{ "%s": ["x"], "entries": [{ "a": 1 }] }' '$comment' > "$LEDGER"
  PL_PATH="$LEDGER" run bun "$FX"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "_readme"
}

@test "an unknown top-level key is rejected (one parametric shape, nothing else)" {
  printf '{ "_readme": ["x"], "entries": [{ "a": 1 }], "stray": true }' > "$LEDGER"
  PL_PATH="$LEDGER" run bun "$FX"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "stray"
}

@test "an entry that violates the entry schema fails closed with its path" {
  printf '{ "_readme": ["x"], "entries": [{ "why": "ok" }, { "why": "" }] }' > "$LEDGER"
  PL_SCHEMA='{"type":"object","required":["why"],"properties":{"why":{"type":"string","minLength":1}}}' \
    PL_PATH="$LEDGER" run bun "$FX"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "entries\[1\]"
}

@test "a valid array-container ledger loads and returns the array" {
  printf '{ "_readme": ["x"], "entries": [{ "why": "a" }, { "why": "b" }] }' > "$LEDGER"
  PL_SCHEMA='{"type":"object","required":["why"],"properties":{"why":{"type":"string","minLength":1}}}' \
    PL_PATH="$LEDGER" run bun "$FX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^LOADED 2$'
}

@test "a valid object-container ledger loads and returns the keyed object" {
  printf '{ "_readme": ["x"], "workflows": { "a.yaml": { "jobs": {} }, "b.yaml": { "jobs": {} } } }' > "$LEDGER"
  PL_CONTAINER=workflows PL_PATH="$LEDGER" run bun "$FX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^LOADED 2$'
}

@test "an empty object container below the consumer floor fails closed too" {
  printf '{ "_readme": ["x"], "workflows": {} }' > "$LEDGER"
  PL_MIN=1 PL_CONTAINER=workflows PL_PATH="$LEDGER" run bun "$FX"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "항목 0건"
}
