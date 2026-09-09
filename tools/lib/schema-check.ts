// 계약 스키마 미니 검증기 — homelab CLI 결과 계약(cli-result-schema.json) 커널(ajv 무의존).
// **테스트 전용이 아니다**: 골든 픽스처·계약 테스트와 함께 (1) MCP 입력 신뢰 경계(mcp.ts의
// inputSchema 검증), (2) 정책 원장 항목 검증(policy-ledger), (3) 방출 직전 envelope 자기검증
// (contract.ts assertEnvelope — CLI·MCP 양쪽 실전 경로)이 같은 커널을 쓴다.
// 지원 키워드는 아래 KNOWN 화이트리스트가 SSOT이고, 스키마에
// 지원 밖 키워드가 들어오면 **throw로 fail-closed**한다 — "검증기가 모르는 제약"이 조용히
// 통과(vacuous green)하는 것을 막는다. (create-app.ts의 check()는 .app-config.yml 전용으로 별개
// 유지 — 에러 문구·exit 정책이 그 콜사이트 소유이고, 지원 키워드 가드도 test_app-config.bats가
// 따로 갖는다.)
const KNOWN = new Set([
  "$schema", "$id", "title", "description", "x-contract", "definitions", "$ref",
  "type", "enum", "required", "properties", "additionalProperties",
  "pattern", "minimum", "maximum", "items", "minItems", "uniqueItems", "minLength",
  "allOf", "oneOf", "not",
]);
// 키워드 → 적용 type 표(SSOT). 아래 walk에서 구조 제약은 전부 `t === "…"` 분기 **안**에 있어
// (a) `type` 없이는 미평가이고 (b) 선언 type과 다른 키워드도 미평가다 — 둘 다 "아는 제약의
// 미평가"라 fail-closed로 던진다. 로스터 2벌(열거·표)이 드리프트하지 않도록 STRUCT는 이 표에서
// 파생한다. ⚠️ KNOWN에 평가 키워드를 더하면 이 표에도 한 줄을 함께 더한다.
const APPLIES_TO: Record<string, readonly string[]> = {
  properties: ["object"], required: ["object"], additionalProperties: ["object"],
  pattern: ["string"], minLength: ["string"],
  minimum: ["integer", "number"], maximum: ["integer", "number"],
  items: ["array"], minItems: ["array"], uniqueItems: ["array"],
};
const STRUCT = Object.keys(APPLIES_TO);

// val을 sch로 검증해 위반 목록을 돌려준다(빈 배열 = 유효). root는 $ref(#/definitions/*) 해석용
// 루트 스키마 — 정의 자체를 sch로 넘겨 부분 검증할 때도 root는 항상 전체 스키마다.
export function schemaErrors(val: unknown, sch: unknown, root: unknown, path = "$"): string[] {
  const errs: string[] = [];
  const rootAny = root as Record<string, any>;
  const walk = (v: any, s: any, p: string): void => {
    if (s.$ref) {
      const name = String(s.$ref).split("/").pop()!;
      const target = rootAny.definitions?.[name];
      if (!target) { errs.push(`${p}: 해석 불가 $ref ${s.$ref}`); return; }
      s = target;
    }
    for (const k of Object.keys(s)) {
      if (!KNOWN.has(k)) throw new Error(`지원 밖 스키마 키워드 '${k}' (${p}) — schema-check.ts 화이트리스트와 함께 확장해야 검증이 유효하다`);
    }
    // additionalProperties는 boolean만 지원한다(스키마 객체형은 아래 object 분기가 평가하지 않아
    // 조용히 통과했다 — 실측). 필요해지면 그때 구현하고 여기 한 줄을 푼다.
    if ("additionalProperties" in s && typeof s.additionalProperties !== "boolean") {
      throw new Error(`additionalProperties는 boolean만 지원 (${p}) — 스키마 객체형은 평가되지 않는다(fail-closed)`);
    }
    // KNOWN 화이트리스트가 막는 것은 '모르는 키워드'뿐이다. 두 번째 접힘 표면 — **아는 키워드가
    // `type` 부재로 평가되지 않는 것** — 은 같은 자리에서 fail-closed로 닫는다. `{required:[…]}`·
    // `{minLength:1}`은 JSON Schema로 유효한 표기라 작성 실수가 조용히 통과하면 vacuous green이다.
    // 면제는 enum뿐: enum은 값 자체를 판정하고 아래에서 return한다($ref는 :20-25에서 이미 target으로
    // 치환된 뒤라 여기에 남지 않는다). 빈 `{}` 노드(check-ci-parity ENTRY_SCHEMA의 자유 값 필드)는
    // STRUCT 키가 없어 대상이 아니고, allOf/oneOf/not은 형제 키로 따로 평가되므로 면제하지 않는다
    // (`{allOf:[…], required:[…]}`를 면제하면 같은 구멍이 그대로 남는다).
    if (s.type === undefined && !s.enum && STRUCT.some((k) => k in s)) {
      throw new Error(`type 없는 구조 스키마 (${p}) — 구조 제약은 type이 있어야 평가된다(fail-closed)`);
    }
    // 같은 클래스의 두 번째 얼굴 — type **불일치**. `{type:"string", minimum:5}`·`{type:"array",
    // required:[…]}`·`{type:"integer", pattern:"…"}`은 전부 유효한 JSON Schema 표기지만 이 커널의
    // 분기 구조상 영원히 미평가라, 작성 실수가 vacuous green이 된다(실측 3케이스).
    if (s.type !== undefined) {
      for (const k of STRUCT) {
        if (k in s && !APPLIES_TO[k]!.includes(String(s.type))) {
          throw new Error(`type 불일치 제약 '${k}' (${p}) — type ${String(s.type)}에는 평가되지 않는 제약이다(fail-closed)`);
        }
      }
    }
    // 결합 키워드 — verb→result·variant→exitCode 판별(allOf의 각 스키마는 전부, oneOf는 정확히 1개 분기).
    if (s.allOf) for (const branch of s.allOf) walk(v, branch, p);
    if (s.oneOf) {
      const matched = s.oneOf.filter((branch: any) => schemaErrors(v, branch, root, p).length === 0).length;
      if (matched !== 1) errs.push(`${p}: oneOf 분기 정확히 1개가 아니라 ${matched}개 일치`);
    }
    if (s.not) {
      if (schemaErrors(v, s.not, root, p).length === 0) errs.push(`${p}: not 스키마에 일치(금지된 형상)`);
    }
    const t = s.type;
    const is: Record<string, (x: any) => boolean> = {
      object: (x) => x !== null && typeof x === "object" && !Array.isArray(x),
      array: Array.isArray,
      string: (x) => typeof x === "string",
      integer: Number.isInteger,
      number: (x) => typeof x === "number",
      boolean: (x) => typeof x === "boolean",
    };
    // enum은 값 자체를 판정하고 여기서 끝난다 — 다만 형제 `type`을 **단락시키지 않는다**
    // (`{type:"integer", enum:["a"]}`에 "a"가 통과하던 자리 — 실측).
    if (s.enum) {
      if (t && !is[t]?.(v)) { errs.push(`${p}: ${t} 타입이어야 함`); return; }
      if (!s.enum.some((e: any) => e === v)) errs.push(`${p}: ${JSON.stringify(v)}은 enum ${JSON.stringify(s.enum)} 밖`);
      return;
    }
    if (t && !is[t]?.(v)) { errs.push(`${p}: ${t} 타입이어야 함`); return; }
    if (t === "string") {
      // pattern 위반은 속성의 description(있으면)을 덧붙인다 — MCP -32602가 "왜 거부됐고 무엇을 줘야 하는지"를
      // 담게 하는 유일한 자리다(JSON Schema에는 커스텀 메시지가 없다 — 예: 틸드 경로 거부 + 안내 문구).
      if (s.pattern && !new RegExp(s.pattern).test(v)) errs.push(`${p}: 패턴 ${s.pattern} 불일치${typeof s.description === "string" && s.description !== "" ? ` — ${s.description}` : ""}`);
      if (s.minLength != null && v.length < s.minLength) errs.push(`${p}: 길이 < ${s.minLength}`);
    }
    if (t === "integer" || t === "number") {
      if (s.minimum != null && v < s.minimum) errs.push(`${p}: < ${s.minimum}`);
      if (s.maximum != null && v > s.maximum) errs.push(`${p}: > ${s.maximum}`);
    }
    if (t === "array") {
      if (s.minItems != null && v.length < s.minItems) errs.push(`${p}: 최소 ${s.minItems}개`);
      if (s.uniqueItems && new Set(v.map((x: any) => JSON.stringify(x))).size !== v.length) errs.push(`${p}: 중복 항목`);
      if (s.items) v.forEach((x: any, i: number) => walk(x, s.items, `${p}[${i}]`));
    }
    if (t === "object") {
      for (const r of s.required ?? []) if (!(r in v)) errs.push(`${p}.${r}: 필수`);
      for (const [k, x] of Object.entries(v)) {
        if (s.properties?.[k]) walk(x, s.properties[k], `${p}.${k}`);
        else if (s.additionalProperties === false) errs.push(`${p}.${k}: 알 수 없는 필드`);
      }
    }
  };
  walk(val, sch, path);
  return errs;
}
