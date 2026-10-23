// 명령 정의와 명령이 받는 문맥의 모양. 명령 파일 하나가 defineCommand 하나를 default로 내보내고 registry.ts가 정적 import한다.
// (bun build --compile 실행 파일은 실행 때 파일을 찾지 못하므로 정적 import만 쓴다.)
//
// 구조(사용자 결정 2026-10-23, #873 3라운드): 명령은 외부 명령을 직접 실행할 수 없다. 받는 것은 타입 있는 어댑터뿐이고
// 어댑터마다 argv 모양이 고정이다. 읽기 문맥(ReadCtx)에는 쓰기 함수가 아예 없고, 쓰기 문맥(WriteCtx)은 엔진이
// Step.apply() 한 번마다 새로 만들어 넘긴 뒤 끝나면 폐기한다. 명령이 import할 수 있는 core 모듈은
// command·names·result·pr뿐이다(정적 시험).
import type { ArgSpec, FlagSpec, Input } from "./args";
import type { Mode, Result, State, Action, Status } from "./result";
import type { Secret } from "./secret";

export type { Secret };

// 범용 kubectl 조회가 받는 리소스. Secret은 없다(값은 secretHash·secretExists로만).
export type KubeKind =
  | "deployment"
  | "pod"
  | "statefulset"
  | "job"
  | "cronjob"
  | "service"
  | "ingress"
  | "pvc"
  | "pv"
  | "namespace"
  | "networkpolicy"
  | "externalsecret"
  | "application"
  | "cluster"
  | "backup"
  | "scheduledbackup"
  | "database"
  | "databaserole"
  | "event";

export type KubeRead = {
  // 없으면 null. 그 밖의 실패(인증·연결)는 던진다.
  get(kind: KubeKind, ns: string | null, name: string): any | null;
  list(kind: KubeKind, ns: string | null, selector?: string): any[];
  // Secret 키 값의 sha256 앞 12자. 그 키 값만 Secret으로 만든다. 없으면 null.
  secretHash(ns: string, name: string, key: string): string | null;
  // Secret이 있는지와 키 이름만.
  secretExists(ns: string, name: string): { exists: boolean; keys: string[] };
  logs(ns: string, deployment: string, opts?: { since?: string; tail?: number }): string;
  canI(verb: "get" | "list" | "create" | "delete" | "patch", kind: KubeKind, ns: string): boolean;
  rolloutStatus(ns: string, deployment: string, timeoutSec?: number): boolean;
  currentContext(): string | null;
};

export type KubeWrite = {
  // ExternalSecret 즉시 동기화(force-sync annotation, rotate.md 0절).
  forceSync(ns: string, externalSecret: string): void;
  rolloutRestart(ns: string, deployment: string): void;
  // GitOps 밖 일회성 복원 객체(C.5.7). 라벨 homelab.ukyi.app/restore 필수, 어디에도 Secret이 있으면 거부.
  createRestoreObject(ns: string, manifest: Record<string, unknown>): void;
  deleteRestoreObjects(ns: string, runId: string): void;
};

export type InfisicalRead = {
  has(path: string, key: string): boolean;
  listKeys(path: string): string[];
  // 불투명한 값. 명령은 열어 볼 수 없고 setValue로 넘기기만 한다.
  getValue(path: string, key: string): Secret | null;
  valueHash(path: string, key: string): string | null;
  // doctor용: HOMELAB_INFISICAL_PROJECT_ID가 있는지·형식이 맞는지(묻지 않는다).
  projectStatus(): "ok" | "missing" | "invalid";
};

export type InfisicalWrite = {
  // 16자 이상, .env 한 줄로 왕복하는 값만(infisical.ts 실측 주석).
  setValue(path: string, key: string, value: Secret): void;
  removeKey(path: string, key: string): void;
};

export type GhResponse = { status: number; json: any };

export type GhRead = {
  // GitHub REST GET. 경로는 repos/ukyi-app/…, orgs/ukyi-app/…, user만.
  get(path: string): GhResponse;
  login(): string;
};

export type RepoRead = {
  mainSha(): string;
  // 저장소 파일 원문. 없으면 null.
  readFile(path: string, ref?: string): string | null;
};

export type GhcrRead = {
  // 익명 pull 토큰 응답 코드(C.7 app add: 200이어야 public 이미지).
  anonymousPullStatus(app: string): number;
};

export type ToolName = "kubectl" | "infisical" | "terraform" | "gh" | "git" | "curl" | "jq";

export type ToolsRead = {
  // 버전 출력(stdout). 도구가 없으면 found false.
  version(tool: ToolName): { found: boolean; ok: boolean; output: string };
  ghAuthOk(): boolean;
  infisicalLogin(): "ok" | "missing" | "no";
};

// github 하위 명령(kind delegate)만 받는다. main을 core 임시 폴더로 fresh clone하고 그 안의 tools/tf-github.sh를 부른다.
export type GithubDelegate = {
  run(sub: "plan" | "verify" | "apply", opts?: { allowDestroy?: boolean }): number;
};

export type Observation = {
  state: State;
  action: Action;
  // 사람용 설명("없음 → 생성"). 값은 넣지 않는다(출력 계층이 다시 막는다).
  detail: string;
  // same이어도 바깥을 기다리면(예 "PR #12 병합 대기") apply 결과가 waiting(3)이 된다.
  wait?: string;
  // 이 단계가 막혔을 때 사람이 할 일.
  next?: string;
  // same이지만 알려 둘 것. 실패로 세지 않고 "주의:" 줄로 보인다(전체 읽기 한 번만).
  warn?: string;
};

export type ReadCtx = {
  mode: Mode;
  json: boolean;
  // 사람이 친 명령줄(--json 뺌). 다음 행동 문구에 쓴다.
  line: string;
  k8s: KubeRead;
  infisical: InfisicalRead;
  gh: GhRead;
  repo: RepoRead;
  ghcr: GhcrRead;
  tools: ToolsRead;
  // kind delegate 명령에만 있다.
  github?: GithubDelegate;
  engine(plan: Plan): Promise<Result>;
  // 진행 줄. stderr로 간다(stdout은 결과 하나만).
  progress(line: string): void;
};

// Step.apply() 안에서만 존재한다. apply가 끝나면 폐기되어 붙잡아 둔 뒤 쓰면 모든 호출이 막힌다.
export type WriteCtx = {
  k8s: KubeRead & KubeWrite;
  infisical: InfisicalRead & InfisicalWrite;
  gh: GhRead;
  repo: RepoRead;
  ghcr: GhcrRead;
  // 영숫자 40자.
  generatePassword(): Secret;
  // stdin(파이프) 또는 tty(에코 없음)에서 시크릿 한 개. 16자 이상만.
  readSecretInput(prompt: string): Secret;
  progress(line: string): void;
};

// 명령의 run()이 받는 문맥.
export type Ctx = ReadCtx;

export type Step = {
  id: string;
  target: string;
  read(ctx: ReadCtx): Promise<Observation>;
  // 없으면 확인 단계: same이 아니면 명령이 실패한다(apply에서는 아무것도 쓰기 전에).
  apply?(w: WriteCtx, seen: Observation): Promise<void>;
};

export type Plan = {
  command: string;
  app?: string;
  steps: Step[];
  notes?: string[];
  title?: string;
  // 없으면 엔진의 기본 다음 행동(pending이면 같은 명령에 --apply).
  next?: (status: Status) => string | null;
};

// change: 기본 plan, --apply로 실행. read: 상태를 안 바꾼다(--apply는 64). delegate: github 래퍼, 종료 코드 위임.
export type Kind = "change" | "read" | "delegate";

export type CommandSpec = {
  path: string[];
  summary: string;
  kind: Kind;
  // delegate만: 래퍼가 상태를 바꾸는지(github apply).
  delegateMode?: "read" | "apply";
  args: ArgSpec[];
  flags: FlagSpec[];
  // 자리표시(아직 구현 전) 명령이면 담당 티켓. 구현하면 지운다.
  placeholder?: string;
  run(ctx: ReadCtx, input: Input): Promise<Result>;
};

export function defineCommand(spec: CommandSpec): CommandSpec {
  return spec;
}

// 자리표시. 담당 티켓이 이 파일을 통째로 바꾼다.
export function placeholder(spec: Omit<CommandSpec, "run" | "placeholder">, ticket: string): CommandSpec {
  return {
    ...spec,
    placeholder: ticket,
    async run(ctx) {
      const command = spec.path.join(" ");
      return {
        command,
        mode: ctx.mode,
        status: "failed",
        steps: [],
        notes: [],
        next: null,
        error: { message: `homelab ${command}은 아직 구현 전이다(${ticket})`, next: "homelab doctor" },
      };
    },
  };
}
