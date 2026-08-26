// 외부 명령 실행 seam — 이 레포 TS 도구의 subprocess 실행이 전부 지나는 자리(lib-convergence d6).
// 판정 정책(무엇이 실패인가·실패를 어떻게 보고하는가)은 콜사이트 소유 — 여기는 실행·캡처·관측만
// 한다(encoding utf8·timeout 30s 고정). 명명 adapter(gh/git/kubeseal)는 sh의 커맨드 고정형이다.
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
export type Cmd = { ok: boolean; out: string; err: string; errKind?: ErrKind };
// timeoutMs — 기본 30s(느린 push/pr 경로는 콜사이트가 올린다). maxBuffer — 기본 8MiB:
// Node 기본 1MiB는 ENOBUFS로 죽고 그 죽음이 errKind:"spawn"으로만 보인다(ensure-bump-pr가
// 4MiB로 세 번 실측한 클래스 — 이관 클러스터가 조용히 퇴행하지 않게 seam 기본을 넉넉히 둔다).
// inherit — stdio를 부모에 물린다(대화형/스트리밍 콜사이트용 · out/err는 빈 문자열이 된다).
export type ExecOpts = { cwd?: string; input?: string; timeoutMs?: number; maxBuffer?: number; inherit?: boolean };

function ledger(cmd: string, args: string[]): void {
  const f = process.env.HOMELAB_EXEC_LEDGER;
  if (!f) return;
  try { appendFileSync(f, JSON.stringify({ cmd, args }) + "\n"); } catch { /* 관측은 실행을 막지 않는다 */ }
}

export function sh(cmd: string, args: string[], opts: ExecOpts = {}): Cmd {
  ledger(cmd, args);
  const r = spawnSync(cmd, args, {
    encoding: "utf8",
    timeout: opts.timeoutMs ?? 30_000,
    maxBuffer: opts.maxBuffer ?? 8 * 1024 * 1024,
    cwd: opts.cwd,
    input: opts.input,
    stdio: opts.inherit ? "inherit" : undefined,
  });
  if (r.error) {
    const code = (r.error as NodeJS.ErrnoException).code;
    return {
      ok: false, out: "", err: String((r.error as Error).message),
      errKind: code === "ENOENT" ? "not-found" : "spawn",
    };
  }
  return { ok: r.status === 0, out: r.stdout ?? "", err: (r.stderr ?? "").trim() };
}

export function gh(args: string[], opts: ExecOpts = {}): Cmd { return sh("gh", args, opts); }
export function git(args: string[], opts: ExecOpts = {}): Cmd { return sh("git", args, opts); }
export function kubeseal(args: string[], opts: ExecOpts = {}): Cmd { return sh("kubeseal", args, opts); }

// gh api + --jq 결과를 파싱한다. 실패는 null — 콜사이트가 fail-loud 여부를 정한다.
// ⚠️ 오브젝트/배열 jq 전용 — 스칼라 jq(.status 등)는 raw 문자열이 나와 JSON.parse가 깨진다.
//    스칼라는 sh()로 직접 받아 trim해서 쓴다(mutation.ts isDescendant 참고).
export function ghJson(path: string, jq: string): unknown | null {
  const r = gh(["api", path, "--jq", jq]);
  if (!r.ok) return null;
  try { return JSON.parse(r.out); } catch { return null; }
}
