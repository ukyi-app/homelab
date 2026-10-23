// 명령에 줄 문맥을 조립한다(사용자 결정 2026-10-23, #873 3라운드).
// - ReadCtx: 읽기 어댑터만. 그 밑의 exec는 read exec라 쓰기 argv를 실행하지 않는다.
// - WriteCtx: 엔진이 Step.apply() 한 번마다 newWrite()로 만들고 apply가 끝나면 revoke한다. 폐기 뒤에는 쓰기 어댑터·
//   비밀번호 생성·시크릿 입력이 모두 막힌다. 전역 상태가 없어 다른 엔진·병렬 흐름이 이 쓰기 권한을 빌릴 수 없다.
// - github 위임(kind delegate)만 ctx.github를 받는다.
// makeRuntime·makeExec은 main.ts와 시험만 부른다(정적 시험).
import type { ReadCtx, WriteCtx } from "./command";
import { runEngine } from "./engine";
import { PLAN_WRITE_BLOCKED, makeExec, type Exec } from "./exec";
import { ghRead, ghcrRead, githubDelegate } from "./github";
import { infisicalRead, infisicalWrite, projectResolver } from "./infisical";
import { readSecretInput } from "./input";
import { kubeRead, kubeWrite } from "./kubectl";
import { writeStderr } from "./output";
import { repoRead } from "./pr";
import type { Mode } from "./result";
import { registerWriteExec } from "./runtime-internal";
import { newPassword } from "./secret";
import { toolsRead } from "./tools";

export type RuntimeOpts = {
  mode: Mode;
  json: boolean;
  line: string;
  env: Record<string, string | undefined>;
  isTTY: boolean;
  // tty에서 한 줄 묻기(프로젝트 ID처럼 화면에 보여도 되는 값).
  ask: (question: string) => string | null;
  progress: (line: string) => void;
  delegate?: boolean;
  // CLI를 실행한 폴더(github 위임이 원본 checkout을 찾는다). 없으면 process.cwd().
  cwd?: string;
};

export type WriteHandle = { w: WriteCtx; revoke: () => void };

export function makeRuntime(o: RuntimeOpts): ReadCtx {
  const project = projectResolver({ env: o.env, isTTY: o.isTTY, ask: o.ask });
  const readExec: Exec = makeExec("read", { env: o.env, delegate: o.delegate });
  let engineRunning = false;

  const newWrite = (): WriteHandle => {
    if (o.mode !== "apply") throw new Error(`${PLAN_WRITE_BLOCKED}: ${o.mode} 모드에는 쓰기 문맥이 없다`);
    let live = true;
    const exec = makeExec("write", { env: o.env, live: () => live });
    const alive = () => {
      if (!live) throw new Error(`${PLAN_WRITE_BLOCKED}: 끝난 apply의 쓰기 문맥을 다시 썼다(Step.apply 밖)`);
    };
    const w: WriteCtx = {
      k8s: { ...kubeRead(readExec), ...kubeWrite(exec) },
      infisical: { ...infisicalRead(readExec, project), ...infisicalWrite(exec, project) },
      gh: ghRead(readExec),
      repo: repoRead(readExec),
      ghcr: ghcrRead(readExec),
      generatePassword: () => (alive(), newPassword()),
      readSecretInput: (prompt) => (alive(), readSecretInput(o.isTTY, (q) => writeStderr(q), prompt)),
      progress: o.progress,
    };
    registerWriteExec(w, exec);
    return { w, revoke: () => (live = false) };
  };

  const ctx: ReadCtx = {
    mode: o.mode,
    json: o.json,
    line: o.line,
    k8s: kubeRead(readExec),
    infisical: infisicalRead(readExec, project),
    gh: ghRead(readExec),
    repo: repoRead(readExec),
    ghcr: ghcrRead(readExec),
    tools: toolsRead(readExec),
    progress: o.progress,
    // 엔진은 한 번에 하나만 돈다(중첩·병렬 거부). 한 apply의 쓰기 문맥이 살아 있는 동안 다른 엔진의 단계가 돌 수 없다.
    engine: async (plan) => {
      if (engineRunning) throw new Error("엔진은 한 번에 하나만 돈다(중첩·병렬 실행을 받지 않는다)");
      engineRunning = true;
      try {
        return await runEngine(ctx, plan, newWrite);
      } finally {
        engineRunning = false;
      }
    },
  };
  if (o.delegate) {
    // github apply만 래퍼 하나를 쓰기로 실행한다(쓰기 exec의 delegate 규칙이 래퍼 밖 쓰기를 막는다).
    const writeOnce = () => (o.mode === "apply" ? makeExec("write", { env: o.env, delegate: true, live: () => true }) : null);
    ctx.github = githubDelegate(makeExec("read", { env: o.env, delegate: true }), writeOnce, o.env, o.json, o.cwd ?? process.cwd());
  }
  return ctx;
}
