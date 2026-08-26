// 정책 원장 리더 — lib-convergence d1, **축소 범위**(design r1-4 · CONTEXT.md 「정책 원장」).
// 소유하는 것: fail-closed 로딩(부재·파싱 실패 = 무조건 throw · 항목 수 바닥값은 소비자 소유) ·
// 통일 shape(`{_readme, <container>}` — 주석 키는 `_readme`뿐, 그 밖의 최상위 키는 거부) ·
// schema-check 재사용 **항목 구조** 검증.
// 소유하지 않는 것: 미선언·죽은-선언 양방향 대조 — 소비자 3곳의 대조 의미론이 실질적으로
// 다르므로(중첩 워크플로/job 신원 · CI-step 커버리지 · 이미지 wildcard/면제) 콜사이트에 남긴다.
// 공통 대조 interface는 공통형이 실증될 때 추출한다(adapter 하나 = 가설 seam).
//
// throw로 알린다 — 종료코드·문구 채널은 콜사이트(대개 guardMain의 enumerate/check 예외 경로)
// 소유다. 컨테이너 값은 배열(unowned/steps/metrics) 또는 키드 객체(workflows) 둘 다 허용한다.
import { readFileSync } from "node:fs";
import { schemaErrors } from "./schema-check.ts";

export function readLedger<T = unknown>(opts: {
  path: string;        // 원장 경로(root 기준)
  container: string;   // 항목 컨테이너 키 — unowned / workflows / steps / metrics …
  entrySchema?: unknown; // 항목별 구조 검증(schema-check) — 조건부·교차 의미론은 콜사이트
  // 항목 수 바닥값(기본 0 = 빈 원장 허용). "정당한 0건"과 "붕괴한 0건"의 구별은 도메인 지식이라
  // 임계값은 소비자가 소유한다(scripts/lib/scan-floor.sh와 같은 규율 — image-ownership의 빈
  // unowned는 이상적 상태이고, ci-parity의 빈 steps는 미계상 대조가 어차피 red를 낸다).
  // **부재·파싱 실패는 여전히 무조건 red**다 — 이 바닥값은 "존재하되 비었다"에만 적용된다.
  minEntries?: number;
  root?: string;       // 기본 "."
}): T {
  const p = opts.path.startsWith("/") ? opts.path : `${opts.root ?? "."}/${opts.path}`;
  let raw: string;
  try {
    raw = readFileSync(p, "utf8");
  } catch (e) {
    // 부재를 '항목 0개'로 위장하는 것이 이 리더가 막는 첫 번째 fail-open이다(existsSync ? … : [] 폴백 클래스).
    throw new Error(
      `${opts.path}: 정책 원장 읽기 실패(${e instanceof Error ? e.message : String(e)}) — 부재는 '항목 0개'가 아니라 red다(fail-closed)`,
    );
  }
  let j: unknown;
  try {
    j = JSON.parse(raw);
  } catch (e) {
    throw new Error(`${opts.path}: JSON 파싱 실패 — ${e instanceof Error ? e.message : String(e)}`);
  }
  if (!j || typeof j !== "object" || Array.isArray(j)) {
    throw new Error(`${opts.path}: 원장 루트는 객체여야 한다(통일 shape: {_readme, ${opts.container}})`);
  }
  const obj = j as Record<string, unknown>;
  for (const k of Object.keys(obj)) {
    if (k !== "_readme" && k !== opts.container) {
      throw new Error(
        `${opts.path}: 허용 밖 최상위 키 '${k}' — 통일 shape는 {_readme, ${opts.container}}다(옛 주석 키 $comment는 _readme로)`,
      );
    }
  }
  const v = obj[opts.container];
  let entries: [string, unknown][];
  if (Array.isArray(v)) entries = v.map((e, i) => [`${opts.container}[${i}]`, e]);
  else if (v && typeof v === "object") entries = Object.entries(v).map(([k, e]) => [`${opts.container}.${k}`, e]);
  else throw new Error(`${opts.path}: '${opts.container}' 배열/객체가 없다`);
  const min = opts.minEntries ?? 0;
  if (entries.length < min) {
    throw new Error(
      `${opts.path}: '${opts.container}' 항목 ${entries.length}건 < 최소 ${min} — 원장 붕괴 의심(항목 0개 위장은 red다, fail-closed)`,
    );
  }
  if (opts.entrySchema) {
    const errs: string[] = [];
    for (const [path, e] of entries) errs.push(...schemaErrors(e, opts.entrySchema, opts.entrySchema, path));
    if (errs.length) throw new Error(`${opts.path}: 원장 항목 검증 실패:\n  ${errs.join("\n  ")}`);
  }
  return v as T;
}
