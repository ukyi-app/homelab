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
  # ⚠️ `-eq 1`은 「리더가 거부했다」와 「policy-ledger.ts가 없어 bun이 죽었다」를 구별하지 못한다
  #    (실측: 리더 삭제 시 12레인 중 이 레인이 그대로 초록). 거부 문구로 가른다.
  [ -f "$ROOT/tools/lib/policy-ledger.ts" ]
  printf '{ "_readme": ["x"], "other": [] }' > "$LEDGER"
  PL_PATH="$LEDGER" PL_CONTAINER=entries run bun "$FX"
  [ "$status" -eq 1 ]
  printf '%s' "$output" | grep -qF -- "허용 밖 최상위 키 'other'"
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

@test "schema-check fails closed on both axes (+ each KNOWN keyword actually reports)" {
  # 헤더가 선언한 fail-closed 성질 두 축 — ① 지원 밖 키워드(KNOWN 화이트리스트) ② `type` 없는 구조
  # 스키마. ②는 pattern/minLength/minimum/required/properties 평가가 전부 `t === "…"` 분기 안이라
  # type이 없으면 어느 것도 실행되지 않는 자리다(모르는 제약이 아니라 **아는 제약의 미평가**).
  cd "$ROOT" || exit 1
  run bun -e '
    import { schemaErrors } from "./tools/lib/schema-check.ts";
    const throws = (v, s) => { try { schemaErrors(v, s, s); return false; } catch { return true; } };
    // typeless 3케이스 — 착지 전에는 셋 다 [](무성 통과)였다.
    const typeless = [
      [{ zzz: 1 }, { properties: { app: { type: "string", minLength: 1 } }, required: ["app"], additionalProperties: false }],
      ["x", { pattern: "^\\d{4}$", minLength: 4 }],
      [-5, { minimum: 1 }],
    ];
    for (const [v, s] of typeless) if (!throws(v, s)) { console.error("NO THROW (typeless):", JSON.stringify(s)); process.exit(1); }
    // 미해석 $ref(오타·삭제된 정의명) 축 — throw는 아니지만 errs.push로 위반 1건을 내야 한다(lib-b-1).
    if (schemaErrors(1, { $ref: "#/definitions/nope" }, { definitions: {} }).length === 0) { console.error("NO ERROR ($ref 해석 실패)"); process.exit(1); }
    // 지원 밖 키워드 축 — 화이트리스트 밖 multipleOf는 throw다.
    if (!throws(1, { type: "integer", multipleOf: 2 })) { console.error("NO THROW (unknown keyword)"); process.exit(1); }
    // 대조군 ①: type이 있으면 throw가 아니라 위반 보고다(가드가 정상 스키마를 죽이지 않는다).
    if (throws({ app: "a" }, { type: "object", properties: { app: { type: "string" } } })) { console.error("FALSE THROW"); process.exit(1); }
    if (schemaErrors({}, { type: "object", required: ["app"] }, {}).length !== 1) { console.error("LOST VIOLATION"); process.exit(1); }
    // KNOWN 화이트리스트는 키워드 **이름**만 통과시킨다 — 그 이름의 평가 구현이 살아 있는지는
    // 아래 다섯 줄이 유일한 증인이다(실측: 다섯 구현을 지워도 소비처 11파일 181/181 초록이었다).
    // ⚠️ KNOWN에 평가 키워드를 더하면 이 자리에 한 줄을 함께 더한다.
    if (schemaErrors("ab", { type: "string", pattern: "^\\d{4}$" }, {}).length !== 1) { console.error("LOST VIOLATION (pattern)"); process.exit(1); }
    if (schemaErrors(0, { type: "integer", minimum: 1 }, {}).length !== 1) { console.error("LOST VIOLATION (minimum)"); process.exit(1); }
    if (schemaErrors(9, { type: "integer", maximum: 1 }, {}).length !== 1) { console.error("LOST VIOLATION (maximum)"); process.exit(1); }
    if (schemaErrors([], { type: "array", minItems: 1 }, {}).length !== 1) { console.error("LOST VIOLATION (minItems)"); process.exit(1); }
    if (schemaErrors([1, 1], { type: "array", uniqueItems: true }, {}).length !== 1) { console.error("LOST VIOLATION (uniqueItems)"); process.exit(1); }
    // 대조군 ②: enum 전용 노드와 빈 {} 노드는 구조 제약이 없어 면제다(ENTRY_SCHEMA의 자유 값 노드).
    if (throws("a", { enum: ["a", "b"] })) { console.error("FALSE THROW (enum)"); process.exit(1); }
    if (throws({ any: 1 }, {})) { console.error("FALSE THROW (empty)"); process.exit(1); }
    // ── 티켓 24: 조용한 통과 3면(전부 착지 전 []였다 — 실측) ─────────────────────────────
    // (1) additionalProperties가 boolean이 아니면 지원 밖 형태다(스키마 객체는 평가되지 않는다).
    if (!throws({ a: 1, b: "x" }, { type: "object", properties: { a: { type: "integer" } }, additionalProperties: { type: "string" } })) { console.error("NO THROW (object additionalProperties)"); process.exit(1); }
    // (2) 선언 type과 안 맞는 제약 키워드는 영원히 미평가다 — 아는 제약의 미평가라 fail-closed.
    if (!throws("x", { type: "string", minimum: 5 })) { console.error("NO THROW (string+minimum)"); process.exit(1); }
    if (!throws([], { type: "array", required: ["x"] })) { console.error("NO THROW (array+required)"); process.exit(1); }
    if (!throws(1, { type: "integer", pattern: "^x$" })) { console.error("NO THROW (integer+pattern)"); process.exit(1); }
    // (3) enum이 형제 type을 단락시키지 않는다 — 값이 enum 멤버여도 type 위반은 위반이다.
    if (schemaErrors("a", { type: "integer", enum: ["a"] }, {}).length !== 1) { console.error("LOST VIOLATION (enum+type)"); process.exit(1); }
    // 대조군 (3): type 없는 enum(권한 어휘 형상)과 additionalProperties:true는 throw가 아니다.
    if (throws("ro", { enum: ["ro", "rw", "admin"] })) { console.error("FALSE THROW (typeless enum)"); process.exit(1); }
    if (throws({ x: 1 }, { type: "object", additionalProperties: true })) { console.error("FALSE THROW (additionalProperties true)"); process.exit(1); }
    // 대조군 (4): 형제 type과 맞는 제약은 그대로 평가된다(표가 정상 스키마를 죽이지 않는다).
    if (schemaErrors("ab", { type: "string", minLength: 4 }, {}).length !== 1) { console.error("LOST VIOLATION (string+minLength)"); process.exit(1); }
    console.log("ok");
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok$"
}

@test "every node of the live schemas walks the hardened schema-check without throwing (4 families, floor 4)" {
  # 새 fail-closed 3면(객체형 additionalProperties·type 불일치 제약·enum 단락)은 **오늘 위반이 0**이라
  # 기존 소비 테스트는 가드가 아예 없어도 초록이다 — 그래서 라이브 스키마 4종의 무침묵을 여기서
  # 명시 단언한다. 값 walk는 값이 닿는 노드만 보므로, 스키마를 **구조로 열거**해 노드마다 커널을
  # 태운다(값은 무관 — 지원 검사가 값 평가보다 앞이다).
  cd "$ROOT" || exit 1
  run bun -e '
    import { schemaErrors } from "./tools/lib/schema-check.ts";
    import { handleRequest } from "./tools/lib/mcp.ts";
    import { ENTRY_SCHEMA } from "./tools/check-ci-parity.ts";
    import { LEDGER_SCHEMA } from "./tools/check-image-ownership.ts";
    import { readFileSync } from "node:fs";
    const cli = JSON.parse(readFileSync("tools/cli-result-schema.json", "utf8"));
    const tools = handleRequest({ jsonrpc: "2.0", id: 1, method: "tools/list" }).result.tools;
    // 노드 열거 — properties·definitions·items·allOf·oneOf·not을 따라 내려간다($ref 해소는 커널 몫).
    // (`$ref` 뒤에 한글을 붙이지 않는다 — bash 3.2가 그 바이트를 변수명에 삼킨다: shell-bash32-traps)
    const nodes = (s, out) => {
      if (s === null || typeof s !== "object" || Array.isArray(s)) return out;
      out.push(s);
      for (const k of ["properties", "definitions"]) for (const v of Object.values(s[k] ?? {})) nodes(v, out);
      for (const k of ["allOf", "oneOf"]) for (const v of s[k] ?? []) nodes(v, out);
      if (s.items) nodes(s.items, out);
      if (s.not) nodes(s.not, out);
      return out;
    };
    const families = [
      ["cli-result-schema", [[cli, cli]]],
      ["mcp inputSchema", tools.map((t) => [t.inputSchema, t.inputSchema])],
      ["ENTRY_SCHEMA", [[ENTRY_SCHEMA, ENTRY_SCHEMA]]],
      ["LEDGER_SCHEMA", [[LEDGER_SCHEMA, LEDGER_SCHEMA]]],
    ];
    if (tools.length !== 9) { console.error("MCP tool 수 " + tools.length + " != 9(손 앵커)"); process.exit(1); }
    let total = 0;
    for (const [label, pairs] of families) {
      let seen = 0;
      for (const [sch, root] of pairs) {
        for (const node of nodes(sch, [])) {
          try { schemaErrors(null, node, root); }
          catch (e) { console.error(label + ": " + (e instanceof Error ? e.message : String(e))); process.exit(1); }
          seen++;
        }
      }
      // 계열마다 바닥값 — 열거가 붕괴하면 "throw 0"이 무측정이 된다.
      if (seen < 3) { console.error(label + ": 노드 " + seen + "건 — 열거 붕괴"); process.exit(1); }
      total += seen;
    }
    if (total < 200) { console.error("전체 노드 " + total + "건 — 열거 붕괴(바닥값 200)"); process.exit(1); }
    console.log("families:" + families.length);
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^families:4$"
}
