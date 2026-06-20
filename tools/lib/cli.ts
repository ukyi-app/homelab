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
