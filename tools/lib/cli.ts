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

// 종료코드 규약(tools/*.ts + scripts/*.sh 가드 공통 — CONTRIBUTING '가드 skip 신호' 절이 산문 SSOT):
//   0=성공(평가했고 통과) · 1=검증/게이트 실패(fail()) · 2=사용법/플래그 파싱 오류(parseFlags catch) ·
//   3=race(전제 상태 변동 — bump-tag expect-current) · 4=skip(검사할 도메인 부재 — 불변식을 **평가하지 않음**).
//   워크플로는 비-0만 보지만 래퍼/사람이 원인 계층을 구분하도록 유지한다.
// 4가 0과 갈라져야 하는 이유: 대상이 없어 건너뛴 것과 검사해서 통과한 것이 같은 코드면 가드가 실제 실행
//   경로를 잃어도 CI가 초록이다(verify-runbook-index 실측 — CI에선 런북이 gitignored라 무조건 skip이었다).
//   4를 낼 때는 같은 줄에서 `SKIP: <가드>: <이유>` 마커를 함께 낸다(정적 짝 검증 —
//   tests/gates/test_guard-skip-signalling.bats).
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
