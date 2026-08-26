// 외부 명령 실행 커널 — homelab CLI 엔진들(status·mutation)이 공유하는 spawnSync 래퍼.
// 판정 정책(무엇이 실패인가·실패를 어떻게 보고하는가)은 콜사이트 소유 — 여기는 실행과
// 캡처만 한다(encoding utf8·timeout 30s 고정). doctor의 gh()는 미설치(ENOENT) 판별이라는
// 자기 정책이 있어 별도 유지한다.
import { spawnSync } from "node:child_process";

export type Cmd = { ok: boolean; out: string; err: string };

export function sh(cmd: string, args: string[], opts: { cwd?: string } = {}): Cmd {
  const r = spawnSync(cmd, args, { encoding: "utf8", timeout: 30_000, cwd: opts.cwd });
  if (r.error) return { ok: false, out: "", err: String((r.error as Error).message) };
  return { ok: r.status === 0, out: r.stdout ?? "", err: (r.stderr ?? "").trim() };
}

// push 라우팅 검사를 생략시키는 테스트 전용 플래그 이름 — bats 하네스가 insteadOf로
// canonical→로컬 bare 재배선을 쓰기 때문에만 존재한다. production 기본은 검사한다.
export const ALLOW_PUSH_REWRITE_ENV = "HOMELAB_TEST_ALLOW_PUSH_REWRITE";

// git 실행 헬퍼 — init·secrets 엔진이 공유한다(양쪽에 있던 동일 래퍼의 수렴).
export function git(cwd: string, args: string[]): Cmd { return sh("git", ["-C", cwd, ...args]); }

// push 라우팅 관측 — `git remote get-url --push --all`만이 pushurl 복수 나열과 insteadOf/
// pushInsteadOf 전개를 전부 반영한다(실측 — `git ls-remote --get-url`은 fetch 지향이라
// pushInsteadOf를 못 본다). 판정은 identity.ts isSafePushRoute 소유 — 여기는 관측만. 실패는 null.
export function pushRoutes(cwd: string): string[] | null {
  const r = git(cwd, ["remote", "get-url", "--push", "--all", "origin"]);
  if (!r.ok) return null;
  return r.out.split("\n").map((s) => s.trim()).filter((s) => s !== "");
}

// gh api + --jq 결과를 파싱한다. 실패는 null — 콜사이트가 fail-loud 여부를 정한다.
// ⚠️ 오브젝트/배열 jq 전용 — 스칼라 jq(.status 등)는 raw 문자열이 나와 JSON.parse가 깨진다.
//    스칼라는 sh()로 직접 받아 trim해서 쓴다(mutation.ts isDescendant 참고).
export function ghJson(path: string, jq: string): unknown | null {
  const r = sh("gh", ["api", path, "--jq", jq]);
  if (!r.ok) return null;
  try { return JSON.parse(r.out); } catch { return null; }
}
