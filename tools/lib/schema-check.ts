// 계약 스키마 미니 검증기 — homelab CLI 결과 계약(cli-result-schema.json)의 골든 픽스처·계약
// 테스트 전용 커널(ajv 무의존). 지원 키워드는 아래 KNOWN 화이트리스트가 SSOT이고, 스키마에
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
// 구조 제약 키워드 — 아래 walk에서 전부 `t === "…"` 분기 **안**에 있어 `type` 없이는 미평가다.
const STRUCT = [
  "properties", "required", "additionalProperties",
  "pattern", "minLength", "minimum", "maximum", "items", "minItems", "uniqueItems",
];

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
    // 결합 키워드 — verb→result·variant→exitCode 판별(allOf의 각 스키마는 전부, oneOf는 정확히 1개 분기).
    if (s.allOf) for (const branch of s.allOf) walk(v, branch, p);
    if (s.oneOf) {
      const matched = s.oneOf.filter((branch: any) => schemaErrors(v, branch, root, p).length === 0).length;
      if (matched !== 1) errs.push(`${p}: oneOf 분기 정확히 1개가 아니라 ${matched}개 일치`);
    }
    if (s.not) {
      if (schemaErrors(v, s.not, root, p).length === 0) errs.push(`${p}: not 스키마에 일치(금지된 형상)`);
    }
    if (s.enum) {
      if (!s.enum.some((e: any) => e === v)) errs.push(`${p}: ${JSON.stringify(v)}은 enum ${JSON.stringify(s.enum)} 밖`);
      return;
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
    if (t && !is[t]?.(v)) { errs.push(`${p}: ${t} 타입이어야 함`); return; }
    if (t === "string") {
      if (s.pattern && !new RegExp(s.pattern).test(v)) errs.push(`${p}: 패턴 ${s.pattern} 불일치`);
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
