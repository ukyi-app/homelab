// 외부 명령 실행 커널 — homelab CLI 엔진들(status·mutation)이 공유하는 spawnSync 래퍼.
// 판정 정책(무엇이 실패인가·실패를 어떻게 보고하는가)은 콜사이트 소유 — 여기는 실행과
// 캡처만 한다(encoding utf8·timeout 30s 고정). doctor의 gh()는 미설치(ENOENT) 판별이라는
// 자기 정책이 있어 별도 유지한다.
import { spawnSync } from "node:child_process";

export type Cmd = { ok: boolean; out: string; err: string };

export function sh(cmd: string, args: string[]): Cmd {
  const r = spawnSync(cmd, args, { encoding: "utf8", timeout: 30_000 });
  if (r.error) return { ok: false, out: "", err: String((r.error as Error).message) };
  return { ok: r.status === 0, out: r.stdout ?? "", err: (r.stderr ?? "").trim() };
}

// gh api + --jq 결과를 파싱한다. 실패는 null — 콜사이트가 fail-loud 여부를 정한다.
// ⚠️ 오브젝트/배열 jq 전용 — 스칼라 jq(.status 등)는 raw 문자열이 나와 JSON.parse가 깨진다.
//    스칼라는 sh()로 직접 받아 trim해서 쓴다(mutation.ts isDescendant 참고).
export function ghJson(path: string, jq: string): unknown | null {
  const r = sh("gh", ["api", path, "--jq", jq]);
  if (!r.ok) return null;
  try { return JSON.parse(r.out); } catch { return null; }
}
