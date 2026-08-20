// 결과 계약 SSOT 리더 — cli-result-schema.json의 x-contract를 런타임에 읽는다(코드 상수로
// 복제하지 않는다 — 스키마 파일이 유일한 정의처). homelab.ts(CLI 셸)·lib/verbs.ts(operation
// catalog)·이후 MCP 서버가 이 모듈을 공유한다. import.meta.url 기준 해석이라 어느 디렉토리에서
// 실행해도(앱 레포 안 포함) 동작한다.
import { readFileSync } from "node:fs";

const SCHEMA = JSON.parse(readFileSync(new URL("../cli-result-schema.json", import.meta.url), "utf8"));
const CONTRACT = SCHEMA["x-contract"];

export const ENVELOPE: string = CONTRACT.envelope;
export const EXIT: Record<string, number> = CONTRACT.exitCodes;
export const USAGE_EXIT: number = CONTRACT.usageExit;

// 계약 envelope — 동사 operation의 반환 단위이자 MCP tool 결과의 재사용 단위(계약 한 벌).
export type Envelope = {
  schema: string;
  verb: string;
  variant: string;
  exitCode: number;
  omitted: string[];
  result: unknown;
};

// variant → 종료코드(x-contract.exitCodes). 매핑 부재는 계약 파손이라 fail-closed.
export function exitFor(variant: string): number {
  const code = EXIT[variant];
  if (code === undefined) throw new Error(`계약 파손: variant '${variant}'의 종료코드 매핑이 스키마에 없다`);
  return code;
}
