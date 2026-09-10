// 외부 명령 실행 seam — 이 레포 TS 도구의 subprocess 실행이 전부 지나는 자리.
// 판정 정책(무엇이 실패인가·실패를 어떻게 보고하는가)은 콜사이트 소유 — 여기는 실행·캡처·관측만
// 한다(encoding utf8 · timeout 기본 30s/0=무제한 — ExecOpts 참조). 명명 adapter(gh/git/kubeseal)는 sh의 커맨드 고정형이다.
//
// errKind — 실행 자체가 실패한 종류. "not-found"=바이너리 부재(ENOENT) · "timeout"=시간 초과
// (ETIMEDOUT) · "overflow"=maxBuffer 초과(ENOBUFS) · "spawn"=그 외. 셋을 한 값으로 접으면 원인이
// 통째로 지워진다(doctor.ts의 오진 주석이 지목한 클래스). 비-0 종료는 errKind 없이 ok:false다 —
// rc 의미론은 콜사이트가 판정한다. 소비자: doctor의 미설치 진단, 변이 엔진의 디스패치 타임아웃
// 관용(timeout = '실패'가 아니라 '결과 미상' — mutation.ts 1단계).
//
// 재시도 정책(선언): **seam은 재시도하지 않는다.** sh()는 spawnSync 1회이고
// 백오프도 없다 — 재시도는 콜사이트 정책이며 **변이 argv(`gh workflow run`)는 어떤 층에서도 재시도하지
// 않는다**(타임아웃은 '실패'가 아니라 '결과 미상'이라 재시도가 곧 두 개의 run이다).
// ⚠️ 변이 엔진의 폴링 루프와 PR 목록 grace 재조회(mutation.ts PR_GRACE_RETRIES)는 **관측 재조회**지
// 변이 재시도가 아니다 — 부수효과 0인 읽기를 반복해 미확정을 확정으로 바꾸는 것뿐이다.
//
// HOMELAB_EXEC_LEDGER — env 주입 **관측 레버**(계약은 테스트가 강제한다 — 테스트 전용이 아니다).
// 설정되면 호출마다 {cmd, args} 한 줄을 JSONL로 append한다. 이 레포에서 유일한 디버그 축이라
// tools/README.md·`homelab --help`가 운영자에게 공개한다: **사전 무장 opt-in**이고
// 소급 기록은 불가능하다. 민감값 노출 표면은 전 콜사이트 확인 결과 없다 — 변이 argv는 이름·불리언·
// correlation뿐, 자격은 `--body-file` 경로로만, 봉인 평문은 kubeseal stdin 전용이다.
// ⚠️ stdin(input)은 **절대 기록하지 않는다** — kubeseal 평문이 지나는 채널이다. stdout/stderr도
// 넣지 않는다(kubectl은 키 부재 시 Secret을 base64째 stderr에 덤프한다 — conn-url의 라이브 실측).
// 원장은 관측 편의라 기록 실패가 실행을 막지 않는다(prod 경로 무영향).
import { appendFileSync } from "node:fs";
import { spawnSync } from "node:child_process";

export type ErrKind = "not-found" | "timeout" | "overflow" | "spawn";
// status — 자식의 exit code(실행 실패·시그널 사망이면 null). rc **의미론**은 콜사이트 소유지만
// rc **값** 자체는 seam이 나른다(bump 클러스터 이관의 실증 소비자: 러너의 `exit N` 실패 로그).
// signal — 자식을 죽인 시그널(없으면 부재). SIGKILL 사망은 r.error가 없어 **정상 분기**로 오고
// (ok:false·status null·stderr는 흔히 빈 문자열) 이 필드가 없으면 콜사이트의 사유가 빈 문자열이
// 된다 — '실패했는데 이유가 없다'가 오진을 만든다(실측).
export type Cmd = { ok: boolean; status: number | null; out: string; err: string; errKind?: ErrKind; signal?: string };
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

// git 실행의 env 위생 — **cmd === "git"인 모든 호출**에 건다. 명명 adapter(git())만
// 감싸면 `sh("git", ["clone", …])` 직접 호출(init.ts의 템플릿 클론)이 규약 밖에 남는다: 드리프트가
// 없는 자리는 adapter가 아니라 seam 본체다.
//   · GIT_TERMINAL_PROMPT=0 — 자격이 없으면 프롬프트 대신 **즉시** 죽는다. 이게 없으면 push/clone이
//     자격 입력에서 블록하고, 그 hang은 --wait의 deadline **바깥**이라 pendingReason도 안 나온다
//     (자식이 살아 있으므로 seam의 timeoutMs만이 유일한 탈출구다).
//     ⚠️ GIT_SSH_COMMAND(BatchMode=yes)는 **넣지 않는다** — 사용자의 ssh 설정(ProxyCommand·
//     IdentityAgent·Include)을 통째로 덮는 부작용이 봉인 이득보다 크다. 그래서 ssh 라우트의
//     호스트키 프롬프트는 **미봉인으로 남는다**(알려진 잔여 — canonical 라우트는 https다).
//   · GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE 스크럽 — 상속되면 `git -C <cwd>`가 **다른 레포**를 본다
//     (실측: GIT_DIR=a/.git 하에서 `git -C b rev-parse HEAD`는 a의 HEAD, `status --porcelain`은
//     a의 인덱스 vs b의 트리 차분을 낸다). secrets의 선행 조건 판정(브랜치·클린 트리·staged
//     완전성·HEAD)과 init의 커밋이 전부 이 adapter 위에 있어, git hook(pre-commit·post-checkout이
//     이 셋을 export한다) 안에서 CLI/MCP를 띄우면 판정 대상이 cwd가 아니게 된다.
//     ⚠️ 삭제 allowlist만 둔다 — GIT_CONFIG_GLOBAL/GIT_CONFIG_SYSTEM 상속은 bats 하네스가
//     의존한다(cli_stub_init이 그 둘로 호스트 전역 설정을 격리한다). 여기서 지우면 하네스가
//     호스트 gitconfig에 종속된다.
function gitEnv(): NodeJS.ProcessEnv {
  const { GIT_DIR: _dir, GIT_WORK_TREE: _work, GIT_INDEX_FILE: _index, ...rest } = process.env;
  return { ...rest, GIT_TERMINAL_PROMPT: "0" };
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
    env: cmd === "git" ? gitEnv() : undefined,
  });
  if (r.error) {
    const code = (r.error as NodeJS.ErrnoException).code ?? "";
    // 자식이 **죽기 전에 쓴 stderr**를 버리지 않는다 — ETIMEDOUT·ENOBUFS 모두 부분 출력이 남아
    // 있고(Bun 1.3.14 실측), 그 몇 줄이 '왜 멈췄나'의 유일한 단서다. spawnSync 메시지(한 줄)
    // 뒤에 붙여 사유 계층(무엇이 죽였나 / 자식이 뭐라 했나)을 둘 다 남긴다.
    return {
      ok: false, status: null, out: "",
      err: [String((r.error as Error).message), (r.stderr ?? "").trim()].filter(Boolean).join("\n"),
      errKind: ERR_KIND_BY_CODE[code] ?? "spawn",
      signal: r.signal ?? undefined,
    };
  }
  return { ok: r.status === 0, status: r.status, out: r.stdout ?? "", err: (r.stderr ?? "").trim(), signal: r.signal ?? undefined };
}

// errno → errKind. 목록 밖은 "spawn"(총체성은 콜사이트가 아니라 여기가 소유한다).
const ERR_KIND_BY_CODE: Record<string, ErrKind> = { ENOENT: "not-found", ETIMEDOUT: "timeout", ENOBUFS: "overflow" };

// 다행 stderr에서 **사유** 한 줄을 고른다. 첫 줄이 사유가 아닌 도구가 있다 — 실측(git 2.53.0,
// `push -q` non-fast-forward): 1행 `To <url>`, 2행 ` ! [rejected] HEAD -> main (fetch first)`,
// 3행 `error: failed to push some refs`. `split("\n")[0]` 규약은 gh(1행 완결)·git clone(`fatal:`
// 1행)에는 맞지만 push에서만 사유를 통째로 지운다.
// 우선순위: `error:`/`fatal:`/`!`로 시작하는 첫 줄 → 없으면 `To `/`hint:`가 아닌 첫 줄 → 첫 줄.
// 빈 입력은 빈 문자열이다(폴백 문구 선택은 콜사이트 소유 — 여기서 지어내지 않는다).
export function firstReason(err: string): string {
  const lines = err.split("\n").map((l) => l.trimEnd()).filter((l) => l.trim() !== "");
  const strong = lines.find((l) => /^(error:|fatal:|!)/.test(l.trim()));
  if (strong !== undefined) return strong.trim();
  const weak = lines.find((l) => !/^(To |hint:)/.test(l.trim()));
  return (weak ?? lines[0] ?? "").trim();
}

// push 실패 사유 + **다음 행동**. GIT_TERMINAL_PROMPT=0 아래서 자격 helper가 없으면
// https push는 `fatal: could not read Username for '…': terminal prompts disabled`로 즉시 죽는다.
// 그 줄은 '망 실패'가 아니라 **설정 부재**라 다음 행동이 정해져 있다(`gh auth setup-git`이
// credential.helper를 심는다) — 그런데 종전 문구는 사유만 옮겨 실어, 운영자가 네트워크·권한을
// 뒤지게 만들었다. 문구 SSOT는 이 헬퍼 하나다: 콜사이트(init 첫 push · secrets chain push) 둘이
// 손으로 복사하면 한쪽만 고쳐진다(열거 붕괴).
// 판정은 자격 계열 사유에만 붙인다 — 무조건 붙이면 DNS·거부 실패까지 자격 문제로 오진한다.
export const GIT_CRED_HINT = " — 자격 helper 부재로 보인다: `gh auth setup-git` 실행 후 재시도";
const CRED_REASON_RE = /terminal prompts disabled|could not read (Username|Password)|Authentication failed|Invalid username or (password|token)/i;
export function pushReason(err: string): string {
  const reason = firstReason(err);
  return CRED_REASON_RE.test(reason) ? `${reason}${GIT_CRED_HINT}` : reason;
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

// gh api + --jq 결과의 3상 리더 — 값과 **실패 사유**를 함께 돌려준다. ghJson(아래)이 null로 접어
// 버리는 사유를, 폴링 루프가 pendingReason에 실을 수 있게 하는 자리다.
//   error — 비-0 종료(인증 만료·오프라인·rate limit). 사유 = stderr 첫 줄.
//   parse — rc 0인데 JSON이 아니다. **stderr가 비어 있으므로** 폴백 문구가 필요하다(빈 사유는
//           "실패했는데 이유가 없다"로 보여 오히려 오진을 만든다).
// ⚠️ 오브젝트/배열 jq 전용 — 스칼라 jq(.status 등)는 raw 문자열이 나와 JSON.parse가 깨진다.
//    스칼라는 sh()로 직접 받아 trim해서 쓴다(mutation.ts isDescendant 참고).
// errKind — 실행 자체가 실패한 종류(seam이 나른 값 그대로). 콜사이트가 사유 **문구**를 처방으로
// 번역할 수 있게 남긴다: not-found의 reason은 `spawnSync gh ENOENT`라 운영자에게 무의미하고,
// 그 한 줄이 미인증·404·망 단절과 같은 자리에 놓이면 처방 분기가 원리적으로 불가능하다.
export type GhRead =
  | { kind: "ok"; value: unknown }
  | { kind: "error"; reason: string; errKind?: ErrKind }
  | { kind: "parse"; reason: string };
export function ghRead(path: string, jq: string): GhRead {
  const r = gh(["api", path, "--jq", jq]);
  if (!r.ok) return { kind: "error", reason: r.err.split("\n")[0] || `gh api 비-0 종료(status ${r.status ?? "null"})`, errKind: r.errKind };
  try { return { kind: "ok", value: JSON.parse(r.out) }; }
  catch { return { kind: "parse", reason: "gh api 응답이 JSON이 아니다(jq 투영/응답 형상 확인)" }; }
}

// ghRead의 축약 — 값만 필요한 콜사이트용. 실패는 null(사유가 필요하면 ghRead를 쓴다).
export function ghJson(path: string, jq: string): unknown | null {
  const g = ghRead(path, jq);
  return g.kind === "ok" ? g.value : null;
}
