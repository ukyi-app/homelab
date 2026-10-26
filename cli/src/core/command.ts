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
  | "event"
  | "clustersecretstore"
  | "node"
  | "objectstore";

// 로그 대상. 앱 Deployment 또는 Job(마이그레이션·복원·백업).
export type LogTarget = { deployment: string } | { job: string };

// 복원 실행 기록 ConfigMap 이름(03, restore.md의 $W를 클러스터에 둔 것). 범용 ConfigMap 조회는 없다.
export type RestoreRecordName = "restore-pg" | "restore-vk" | "restore-check";
export type RestoreRecord = { run: string; data: Record<string, string>; resourceVersion: string; uid: string };

// 파드 템플릿이 참조하는 Secret들의 resourceVersion이 템플릿 주석과 같은지(값은 읽지 않는다).
export type PodSecrets = { current: boolean; rolledOut: boolean; secrets: string[] };

export type KubeRead = {
  // 없으면 null. 그 밖의 실패(인증·연결)는 던진다.
  get(kind: KubeKind, ns: string | null, name: string): any | null;
  list(kind: KubeKind, ns: string | null, selector?: string): any[];
  // Secret 키 값의 sha256 앞 12자. 그 키 값만 Secret으로 만든다. 없으면 null.
  secretHash(ns: string, name: string, key: string): string | null;
  // Secret이 있는지, 키 이름, resourceVersion(값 아님).
  secretExists(ns: string, name: string): { exists: boolean; keys: string[]; resourceVersion: string | null };
  // 그 키 값이 needle 원문이나 URL 인코딩 꼴을 품는지(DATABASE_URL 등). Secret·키가 없으면 null.
  secretEmbeds(ns: string, name: string, key: string, needle: Secret): boolean | null;
  // 2초마다 다시 보며 기다린다. 맞으면 true, 시간 초과면 false. timeoutSec ≤ 300.
  waitSecret(ns: string, name: string, key: string, want: { hash: string } | { embeds: Secret }, timeoutSec: number): boolean;
  // kubectl wait --for=jsonpath. jsonpath는 {.status.x.y} 꼴만. 시간 초과면 false, 대상이 없으면 던진다. timeoutSec ≤ 600.
  waitFor(kind: KubeKind, ns: string, name: string, jsonpath: string, value: string, timeoutSec: number): boolean;
  // kubectl wait --for=condition. jobPods는 그 Job의 파드들. timeoutSec ≤ 1800.
  waitCondition(kind: KubeKind, ns: string, target: { name: string } | { jobPods: string }, cond: "Ready" | "ready" | "complete", timeoutSec: number): boolean;
  podSecretsCurrent(ns: string, deployment: string): PodSecrets;
  restoreRecord(ns: string, name: RestoreRecordName): RestoreRecord | null;
  logs(ns: string, target: LogTarget, opts?: { since?: string; tail?: number; previous?: boolean; container?: string }): string;
  canI(verb: "get" | "list" | "create" | "delete" | "patch", kind: KubeKind, ns: string): boolean;
  rolloutStatus(ns: string, deployment: string, timeoutSec?: number): boolean;
  currentContext(): string | null;
};

export type KubeWrite = {
  // ExternalSecret 즉시 동기화(force-sync annotation, rotate.md 0절). waitSec이 있으면 refreshTime·Ready까지 기다리고,
  // 넘으면 ExecTimeout(엔진이 재조회). waitSec ≤ 120.
  forceSync(ns: string, externalSecret: string, opts?: { waitSec?: number }): void;
  rolloutRestart(ns: string, deployment: string): void;
  // 참조 Secret의 resourceVersion 해시를 템플릿 주석 homelab.ukyi.app/secrets-rv에 쓴다(바뀌었을 때만 재시작이 일어난다).
  restartForSecrets(ns: string, deployment: string): void;
  restoreRecordCreate(ns: string, name: RestoreRecordName, run: string, data: Record<string, string>): "created" | "exists";
  // 첫 op가 test /data/run = run이라 남의 실행 기록이면 API 서버가 거부한다. 값 null은 그 키를 지운다.
  restoreRecordUpdate(ns: string, name: RestoreRecordName, run: string, set: Record<string, string | null>): void;
  restoreRecordDelete(ns: string, name: RestoreRecordName, run: string): void;
  // 라벨이 이 실행인 객체 하나만 지우고 사라질 때까지 기다린다.
  deleteRestoreObject(ns: string, kind: "job" | "cluster", name: string, runId: string): void;
  createJobFromCronJob(ns: string, cronjob: string, jobName: string, runId: string): void;
  // data purge 전용. PVC가 묶인 PV(storageClass local-retain, claimRef 확인)의 reclaim을 Delete로.
  setPvReclaimDelete(ns: string, pvc: string): void;
  // GitOps 밖 일회성 복원 객체(C.5.7). 라벨 homelab.ukyi.app/restore 필수, 어디에도 Secret이 있으면 거부.
  createRestoreObject(ns: string, manifest: Record<string, unknown>): void;
  deleteRestoreObjects(ns: string, runId: string): void;
};

export type InfisicalRead = {
  // 폴더가 있는지(부모 폴더 목록에서 이름으로).
  folderExists(path: string): boolean;
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
  // 없는 조각만 바깥부터 만든다(/apps/x/postgres면 /apps → /apps/x → /apps/x/postgres).
  createFolder(path: string): void;
};

export type WebRead = {
  // 공개 host의 응답 코드(status 공개 줄). host는 <이름>.ukyi.app만.
  publicStatus(host: string, path: string): number;
};

// 파드 안 작업(쓰기 문맥만). 셸·SQL 텍스트는 core 상수이고 명령은 이름과 Secret만 넘긴다.
export type PgWrite = {
  // 앱 역할로 primary에 로그인해 본다(rotate.md 3c 5). 비밀번호는 stdin.
  passwordCheck(app: string, password: Secret): "accepted" | "rejected";
};

export type ValkeyCommand = "PING" | "DBSIZE" | "CONFIG GET appendonly" | "CONFIG SET appendonly yes" | "INFO persistence";

export type ValkeyWrite = {
  // deploy/<deployment>(이름은 -valkey로 끝난다)에 <deployment>-auth Secret의 password로 인증해 명령 하나(restore.md 0.3).
  cli(ns: string, deployment: string, cmd: ValkeyCommand): string;
  // AOF가 켜지고 다시 쓰기가 끝날 때까지. 맞으면 true, 시간 초과 false. timeoutSec ≤ 300.
  waitAof(ns: string, deployment: string, timeoutSec: number): boolean;
  // 주어진 비밀번호로 PING(rotate.md 3d). WRONGPASS·NOAUTH면 rejected.
  authCheck(ns: string, deployment: string, password: Secret): "accepted" | "rejected";
};

// 공유 PostgreSQL 앱 DB 복원(restore.md 2절, 03 2부). 흐름·SQL·매니페스트는 core가 갖는다. 명령은 순서(단계)와 표식만 정한다.
// run은 복원 실행 id, 잠금·기록은 앱 ns의 ConfigMap restore-pg(이 실행의 것이어야 한다). 파괴 단계는 core가 잠금·앱 멈춤·입력 고정을 다시 본다.
export type RestoreInputs = { ext: { name: string; schema: string; version: string; owner: string }[]; mainEntries: number; aclEntries: number; aclSuEntries: number };
export type PgRestoreWrite = {
  // 1단계 도우미 Job(database ns, rclone). 같은 이름이 있으면 파드까지 지운 뒤 새로. Ready는 waitCondition으로 본다.
  createR2Helper(run: string): void;
  // 4-1 복원 Job(앱 ns, 앱 역할). img는 cluster pg의 spec.imageName(태그@digest).
  createDbJob(app: string, run: string, img: string): void;
  // 2단계 임시 클러스터. 같은 실행의 것이 이미 있으면 던진다. Ready는 waitCondition(cluster, 1800)으로 본다.
  createTmpCluster(run: string, v: { t1: string; srv: string; img: string; size: string }): void;
  tmpPrimary(run: string): string;
  // 임시 클러스터에 그 앱 DB가 있는지(0·1, restore-check와 2단계 확인. 런북의 "표식 테이블 count"를 대신한다).
  tmpDbCount(run: string, app: string): 0 | 1;
  // 2단계 끝: 지금 임시 주 파드를 기록 tmp에 고정한다(이미 있으면 같은지 확인, 다르면 던진다). 뒤 단계의 덤프·확인은 이 값만 쓴다.
  pinTmpPrimary(app: string, run: string): string;
  // 임시 클러스터가 지금도 이 실행의 복원 원본인지(Ready, 주 파드 = 기록 tmp, 복구 원본·지점).
  srcOk(app: string, run: string, v: { t1: string; srv: string }): boolean;
  r2DumpExists(app: string, run: string): boolean;
  // 되돌림 사본 올리기(primary pg_dump | rclone rcat). 이미 있거나 dropped 뒤면 던진다(덮어쓰지 않는다).
  dumpToR2(app: string, run: string): Promise<void>;
  // 올린 사본을 끝까지 읽는다(rclone cat | pg_restore -f /dev/null). 실패면 던진다.
  r2DumpReadable(app: string, run: string): Promise<void>;
  dbCount(app: string): 0 | 1;
  // rolsuper|rolcreaterole|rolcreatedb|rolreplication|rolbypassrls(4-6: "f|f|f|f|f"여야 한다).
  roleFlags(app: string): string;
  // 복원 Job이 Ready이고 앱 역할로 그 DB(app 또는 postgres)에 접속하는지. 아니면 던진다.
  jobAuth(app: string, run: string, db: "app" | "postgres"): void;
  // 4-2: 목록·확장·ACL을 만들고 검증해 기록 in.*에 고정한다(DB는 그대로).
  prepareInputs(app: string, run: string): Promise<RestoreInputs>;
  // 기록 in.*가 4-2 그대로이고 형식이 맞는지.
  inputsOk(app: string, run: string): boolean;
  // 4-3: 잠금·앱 멈춤·입력·원본·덤프 읽기를 다시 보고, dropped 표시 뒤 DB를 지우고 다시 만든다.
  recreateDatabase(app: string, run: string, v: { t1: string; srv: string }): Promise<"recreated" | "created">;
  // 4-3 끝: 확장을 원본 스키마·버전·소유자로(postgres 소유는 postgres, 앱 소유는 복원 Job이).
  createExtensions(app: string, run: string): void;
  // 4-4 본 복원(앱 역할, --no-owner --no-privileges).
  restoreMain(app: string, run: string): Promise<void>;
  // 4-5 ACL 복원(앱 역할 ACL, 그리고 core가 검증한 postgres용 SQL).
  restoreAcl(app: string, run: string): Promise<void>;
  // 4-5 대조: 임시 클러스터와 복원본의 ACL. diff 줄은 제어 문자를 보이는 꼴로 바꾼 50줄까지.
  aclCompare(app: string, run: string): { same: boolean; diff: string[] };
};

export type HttpWrite = {
  // port-forward로 앱 파드에 붙어 헬스 경로의 응답 코드. 경로는 셋만.
  appStatus(ns: string, deployment: string, port: number, path: "/healthz" | "/healthz/db" | "/healthz/cache"): Promise<number>;
};

// app new(04)의 GitHub 쓰기. 본문·경로는 core 고정.
export type AppRepoWrite = {
  createFromTemplate(app: string): void;
  setRepoSettings(app: string): void;
  enableVulnReporting(app: string): void;
  setForkPrApproval(app: string): void;
};

// 래퍼 plan JSON(tools/tf-github.sh plan --plan-json)의 변경 목록. 0·2가 아니면 changes null.
export type PlanChanges = {
  exitCode: number;
  sha: string | null;
  changes: { address: string; mode: "managed" | "data"; actions: string[]; importing: boolean; moved: boolean }[] | null;
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
  planChanges(): PlanChanges;
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
  // same이고 바깥을 기다리는데, 기다리는 동안 뒤 단계를 돌리면 안 될 때(예 "PR #12(앱 멈춤) 병합 대기").
  // apply는 이 단계에서 멈추고 waiting(3), 뒤 단계는 not-run이다. plan은 뒤 단계도 읽어 보인다. same이 아니면 엔진이 거부한다.
  hold?: string;
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
  web: WebRead;
  // kind delegate 명령과 wrapper 표시 명령(app new)에만 있다.
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
  // tty에서 한 줄(보임)을 받아 expected와 같으면 true. tty가 아니면 false(파이프로 대신 답할 수 없다).
  confirm(question: string, expected: string): boolean;
  web: WebRead;
  pg: PgWrite;
  valkey: ValkeyWrite;
  http: HttpWrite;
  pgRestore: PgRestoreWrite;
  // wrapper 표시 명령(app new)에만 있다.
  github?: { apply(): number };
  appRepo?: AppRepoWrite;
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
  // 단계 줄 뒤에 그대로 보일 여러 줄 원문(logs). 제어 문자는 출력 계층이 바꾼다.
  body?: string;
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
  // change 명령이 래퍼 plan JSON과 apply, 앱 저장소 쓰기를 쓴다(app new). ctx.github·w.github·w.appRepo가 생긴다.
  wrapper?: "plan-json";
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
