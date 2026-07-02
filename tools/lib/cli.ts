// CLI 인자 파싱 SSOT — 흩어진 argv 루프 통일(homelab .ts 도구 전용).
// fail-closed: unknown 플래그 거부, 값이 누락돼 다음 플래그(--)를 삼키는 것 거부.
type FlagSpec = { value: string[]; bool: string[] };

export function parseFlags(argv: string[], spec: FlagSpec): Record<string, string | boolean> {
  const known = new Set([...spec.value, ...spec.bool]);
  const out: Record<string, string | boolean> = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith("--")) throw new Error(`예상치 못한 위치 인자: ${a}`);
    if (!known.has(a)) throw new Error(`알 수 없는 옵션: ${a}`);
    if (spec.bool.includes(a)) { out[a] = true; continue; }
    const v = argv[i + 1];
    if (v === undefined || v.startsWith("--")) throw new Error(`옵션 ${a}에 값이 필요하다(값 누락 또는 다음 플래그 삼킴)`);
    out[a] = v; i++;
  }
  return out;
}

// 종료코드 규약(tools/*.ts 공통):
//   0=성공 · 1=검증/게이트 실패(fail()) · 2=사용법/플래그 파싱 오류(parseFlags catch) · 3=race(전제 상태
//   변동 — bump-tag expect-current). 워크플로는 비-0만 보지만 래퍼/사람이 원인 계층을 구분하도록 유지한다.
export type TypedFlags = {
  str: (k: string, d?: string) => string | undefined;
  bool: (k: string) => boolean;
};

// typed accessor — 콜사이트마다 복제되던 `const arg = (k,d)=>…` 헬퍼의 수렴형.
// 파싱 실패는 parseFlags와 동일하게 throw — 콜사이트가 usage 출력 + exit 2로 처리한다.
export function typedFlags(argv: string[], spec: FlagSpec): TypedFlags {
  const out = parseFlags(argv, spec);
  return {
    str: (k, d) => (typeof out[k] === "string" ? (out[k] as string) : d),
    bool: (k) => out[k] === true,
  };
}
