// 명령에 줄 문맥을 조립한다(사용자 결정 2026-10-23, #873 3라운드).
// - ReadCtx: 읽기 어댑터만. 그 밑의 exec는 read exec라 쓰기 argv를 실행하지 않는다.
// - WriteCtx: 엔진이 Step.apply() 한 번마다 newWrite()로 만들고 apply가 끝나면 revoke한다. 폐기 뒤에는 쓰기 어댑터·
//   비밀번호 생성·시크릿 입력이 모두 막힌다. 전역 상태가 없어 다른 엔진·병렬 흐름이 이 쓰기 권한을 빌릴 수 없다.
// - github 위임(kind delegate)만 ctx.github를 받는다.
// makeRuntime·makeExec은 main.ts와 시험만 부른다(정적 시험).
import type { ReadCtx, WriteCtx } from "./command";
import { runEngine } from "./engine";
import { PLAN_WRITE_BLOCKED, makeExec, makeForward, makePipe, type Exec } from "./exec";
import { pgRestoreWrite } from "./pgrestore";
import { appRepoWrite, ghRead, ghcrRead, githubDelegate, webRead, wrapperApply } from "./github";
import { httpWrite, pgWrite, valkeyWrite } from "./podops";
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
  // change 명령이 래퍼 plan JSON·apply와 앱 저장소 쓰기를 쓴다(app new, CommandSpec.wrapper).
  wrapper?: boolean;
};

export type WriteHandle = { w: WriteCtx; revoke: () => void };

export function makeRuntime(o: RuntimeOpts): ReadCtx {
  const project = projectResolver({ env: o.env, isTTY: o.isTTY, ask: o.ask });
  const readExec: Exec = makeExec("read", { env: o.env, delegate: o.delegate });
  // 기다림 간격. 시험 전용 HOMELAB_TEST_POLL_MS가 줄인다(HOMELAB_TEST_TIMEOUT_MS와 같은 방식).
  const poll = Number(o.env.HOMELAB_TEST_POLL_MS);
  const kube = Number.isFinite(poll) && poll > 0 ? { pollMs: poll } : {};
  const cwd = o.cwd ?? process.cwd();
  // github 래퍼를 부르는 명령(delegate, wrapper)만: 직접 stdio를 쓸 수 있는 읽기 exec.
  const delegateRead = o.delegate || o.wrapper ? makeExec("read", { env: o.env, delegate: true }) : null;
  let engineRunning = false;

  const newWrite = (): WriteHandle => {
    if (o.mode !== "apply") throw new Error(`${PLAN_WRITE_BLOCKED}: ${o.mode} 모드에는 쓰기 문맥이 없다`);
    let live = true;
    const exec = makeExec("write", { env: o.env, live: () => live });
    const alive = () => {
      if (!live) throw new Error(`${PLAN_WRITE_BLOCKED}: 끝난 apply의 쓰기 문맥을 다시 썼다(Step.apply 밖)`);
    };
    const k8sRead = kubeRead(readExec, kube);
    const w: WriteCtx = {
      k8s: { ...k8sRead, ...kubeWrite(exec, kube) },
      infisical: { ...infisicalRead(readExec, project), ...infisicalWrite(exec, project) },
      gh: ghRead(readExec),
      repo: repoRead(readExec),
      ghcr: ghcrRead(readExec),
      generatePassword: () => (alive(), newPassword()),
      readSecretInput: (prompt) => (alive(), readSecretInput(o.isTTY, (q) => writeStderr(q), prompt)),
      // 파이프로 대신 답할 수 없게 tty만 받는다(03 purge의 Infisical 삭제 직전 확인).
      confirm: (question, expected) => (alive(), o.isTTY && o.ask(question) === expected),
      web: webRead(readExec),
      pg: pgWrite(exec, k8sRead),
      valkey: valkeyWrite(exec, k8sRead, kube.pollMs ?? 2_000),
      http: httpWrite(makeForward(exec, { env: o.env, live: () => live })),
      pgRestore: pgRestoreWrite(exec, k8sRead, makePipe({ env: o.env, live: () => live }), (ns, job) => k8sRead.waitCondition("job", ns, { jobPods: job }, "Ready", 60)),
      progress: o.progress,
    };
    if (o.wrapper && delegateRead) {
      // 래퍼 apply 하나만 쓰기다(delegate 쓰기 exec가 래퍼 밖 쓰기를 막는다). 이 apply가 끝나면 함께 막힌다.
      w.github = wrapperApply(delegateRead, makeExec("write", { env: o.env, delegate: true, live: () => live }), { env: o.env, cwd });
      w.appRepo = appRepoWrite(exec);
    }
    registerWriteExec(w, exec);
    return { w, revoke: () => (live = false) };
  };

  const ctx: ReadCtx = {
    mode: o.mode,
    json: o.json,
    line: o.line,
    k8s: kubeRead(readExec, kube),
    infisical: infisicalRead(readExec, project),
    gh: ghRead(readExec),
    repo: repoRead(readExec),
    ghcr: ghcrRead(readExec),
    web: webRead(readExec),
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
  if (delegateRead) {
    // github apply만 래퍼 하나를 쓰기로 실행한다(쓰기 exec의 delegate 규칙이 래퍼 밖 쓰기를 막는다).
    // wrapper 명령(app new)은 run("apply")를 쓰지 않는다. 쓰기는 w.github.apply(Step.apply 안)로만.
    const writeOnce = () => (o.delegate && o.mode === "apply" ? makeExec("write", { env: o.env, delegate: true, live: () => true }) : null);
    ctx.github = githubDelegate(delegateRead, writeOnce, o.env, o.json, cwd);
  }
  return ctx;
}
