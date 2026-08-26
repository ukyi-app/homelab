// 외부 명령 실행 seam — 이 레포 TS 도구의 subprocess 실행이 전부 지나는 자리(lib-convergence d6).
// 판정 정책(무엇이 실패인가·실패를 어떻게 보고하는가)은 콜사이트 소유 — 여기는 실행·캡처·관측만
// 한다(encoding utf8 · timeout 기본 30s/0=무제한 — ExecOpts 참조). 명명 adapter(gh/git/kubeseal)는 sh의 커맨드 고정형이다.
//
// errKind — 실행 자체가 실패한 종류("not-found"=바이너리 부재 ENOENT · "spawn"=그 외 spawn 실패).
// 비-0 종료는 errKind 없이 ok:false다 — rc 의미론은 콜사이트가 판정한다. doctor의 미설치 진단이
// 이 필드의 소비자다(종전 자체 gh() 유지 사유였던 ENOENT 판별이 seam으로 흡수된 자리).
//
// HOMELAB_EXEC_LEDGER — env 주입 관측 원장(테스트 adapter). 설정되면 호출마다 {cmd, args} 한 줄을
// JSONL로 append한다. ⚠️ stdin(input)은 **절대 기록하지 않는다** — kubeseal 평문이 지나는 채널이다.
// 원장은 관측 편의라 기록 실패가 실행을 막지 않는다(prod 경로 무영향).
import { appendFileSync } from "node:fs";
import { spawnSync } from "node:child_process";

export type ErrKind = "not-found" | "spawn";
// status — 자식의 exit code(실행 실패·시그널 사망이면 null). rc **의미론**은 콜사이트 소유지만
// rc **값** 자체는 seam이 나른다(bump 클러스터 이관의 실증 소비자: 러너의 `exit N` 실패 로그).
export type Cmd = { ok: boolean; status: number | null; out: string; err: string; errKind?: ErrKind };
// timeoutMs — 기본 30s(느린 push/pr 경로는 콜사이트가 올린다). **0 = 무제한**(종전 spawnSync
// 무-timeout 동작을 보존해야 하는 이관 콜사이트용 — 기본값 강제는 조용한 동작 변화다).
// maxBuffer — 기본 8MiB: Node 기본 1MiB는 ENOBUFS로 죽고 그 죽음이 errKind:"spawn"으로만 보인다
// (ensure-bump-pr가 4MiB로 세 번 실측한 클래스 — 이관 클러스터가 조용히 퇴행하지 않게 넉넉히 둔다).
// inherit — stdio를 부모에 물린다(대화형/스트리밍 콜사이트용 · out/err는 빈 문자열이 된다).
export type ExecOpts = { cwd?: string; input?: string; timeoutMs?: number; maxBuffer?: number; inherit?: boolean };

function ledger(cmd: string, args: string[]): void {
  const f = process.env.HOMELAB_EXEC_LEDGER;
  if (!f) return;
  try { appendFileSync(f, JSON.stringify({ cmd, args }) + "\n"); } catch { /* 관측은 실행을 막지 않는다 */ }
}

export function sh(cmd: string, args: string[], opts: ExecOpts = {}): Cmd {
  ledger(cmd, args);
  const timeoutMs = opts.timeoutMs ?? 30_000;
  const r = spawnSync(cmd, args, {
    encoding: "utf8",
    timeout: timeoutMs === 0 ? undefined : timeoutMs,
    maxBuffer: opts.maxBuffer ?? 8 * 1024 * 1024,
    cwd: opts.cwd,
    input: opts.input,
    stdio: opts.inherit ? "inherit" : undefined,
  });
  if (r.error) {
    const code = (r.error as NodeJS.ErrnoException).code;
    return {
      ok: false, status: null, out: "", err: String((r.error as Error).message),
      errKind: code === "ENOENT" ? "not-found" : "spawn",
    };
  }
  return { ok: r.status === 0, status: r.status, out: r.stdout ?? "", err: (r.stderr ?? "").trim() };
}

export function gh(args: string[], opts: ExecOpts = {}): Cmd { return sh("gh", args, opts); }
export function kubeseal(args: string[], opts: ExecOpts = {}): Cmd { return sh("kubeseal", args, opts); }

// push 라우팅 검사를 생략시키는 테스트 전용 플래그 이름 — bats 하네스가 insteadOf로
// canonical→로컬 bare 재배선을 쓰기 때문에만 존재한다. production 기본은 검사한다.
export const ALLOW_PUSH_REWRITE_ENV = "HOMELAB_TEST_ALLOW_PUSH_REWRITE";

// git 실행 헬퍼 — init·secrets 엔진 등 cwd 고정 소비자의 계약(#541 시그니처 유지).
// 명명 adapter 확장(errKind·timeoutMs·maxBuffer)은 sh를 경유해 그대로 받는다.
export function git(cwd: string, args: string[], opts: ExecOpts = {}): Cmd { return sh("git", ["-C", cwd, ...args], opts); }

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
  const r = gh(["api", path, "--jq", jq]);
  if (!r.ok) return null;
  try { return JSON.parse(r.out); } catch { return null; }
}
