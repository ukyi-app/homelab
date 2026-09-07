// 결과 계약 SSOT 리더 — cli-result-schema.json의 x-contract를 런타임에 읽는다(코드 상수로
// 복제하지 않는다 — 스키마 파일이 유일한 정의처). homelab.ts(CLI 셸)·lib/verbs.ts(operation
// catalog)·이후 MCP 서버가 이 모듈을 공유한다. import.meta.url 기준 해석이라 어느 디렉토리에서
// 실행해도(앱 레포 안 포함) 동작한다.
import { readFileSync } from "node:fs";
import { schemaErrors } from "./schema-check.ts";

const SCHEMA = JSON.parse(readFileSync(new URL("../cli-result-schema.json", import.meta.url), "utf8"));
const CONTRACT = SCHEMA["x-contract"];

export const ENVELOPE: string = CONTRACT.envelope;
export const EXIT: Record<string, number> = CONTRACT.exitCodes;
export const USAGE_EXIT: number = CONTRACT.usageExit;

// MCP tool 결과 매핑(x-contract.mcp) — variant → isError. failure/race/superseded=에러,
// success/no-op/skip/pending=정상(pending은 재호출이 재개 경로라 에러 아님). MCP 서버가 공유한다.
// 두 목록은 variant enum의 **분할**이다(생성기가 생성 시점에 합집합·교집합·exitCodes 키 집합을
// 단언한다) — 그래서 어디에도 없는 variant는 '정상'이 아니라 계약 파손이다(exitFor와 같은 극성).
// 종전에는 미지 variant가 조용히 isError=false로 접혀, enum·exitCodes에만 추가된 실패 계열
// variant 하나가 에이전트에게 '정상'으로 보였다.
export const MCP_IS_ERROR_VARIANTS: string[] = CONTRACT.mcp.isErrorVariants;
export const MCP_NORMAL_VARIANTS: string[] = CONTRACT.mcp.normalVariants;
export function mcpIsError(variant: string): boolean {
  if (MCP_IS_ERROR_VARIANTS.includes(variant)) return true;
  if (MCP_NORMAL_VARIANTS.includes(variant)) return false;
  throw new Error(`계약 파손: variant '${variant}'의 MCP 매핑이 스키마에 없다(isError/normal 두 목록 밖)`);
}

// 계약 envelope — 동사 operation의 반환 단위이자 MCP tool 결과의 재사용 단위(계약 한 벌).
export type Envelope = {
  schema: string;
  verb: string;
  variant: string;
  exitCode: number;
  omitted: string[];
  result: unknown;
};

// null/undefined 값 키 제거 — 계약 규칙 "값 없음 = 키 부재"(스키마가 JSON null 타입을 두지
// 않는다)의 실행형. 결과 오브젝트를 조립하는 모든 엔진이 공유한다.
export function compact(o: Record<string, unknown>): Record<string, unknown> {
  return Object.fromEntries(Object.entries(o).filter(([, v]) => v !== null && v !== undefined));
}

// 방출 직전 자기검증 — envelope이 자기 계약(cli-result-schema.json)을 지키는지 스스로 잰다.
// **env 게이트 뒤에 숨기지 않는다**: 켜야 도는 검사는 실전 경로에서 영원히 침묵하고, 골든이 없는
// 셀(행렬 38칸 중 절반)은 정확히 그 실전 경로다. 위반은 조용한 잘못된 출력이 아니라 계약 파손이다
// (CLI는 stderr로 죽고, MCP는 서버 루프의 -32603 격리가 받는다). 비용은 방출 1회당 walk 1회다.
export function assertEnvelope(env: Envelope): Envelope {
  const errs = schemaErrors(env, SCHEMA, SCHEMA);
  if (errs.length > 0) {
    throw new Error(`계약 파손: 방출 직전 envelope이 결과 계약을 어긴다 — ${errs.slice(0, 3).join(" | ")}`);
  }
  return env;
}

// variant → 종료코드(x-contract.exitCodes). 매핑 부재는 계약 파손이라 fail-closed.
export function exitFor(variant: string): number {
  const code = EXIT[variant];
  if (code === undefined) throw new Error(`계약 파손: variant '${variant}'의 종료코드 매핑이 스키마에 없다`);
  return code;
}
