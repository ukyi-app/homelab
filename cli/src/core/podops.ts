// 파드 안 작업(쓰기 문맥만). kubectl exec·port-forward는 쓰기로 판정되어 plan에서 돌지 않는다(AC-2).
// 셸 텍스트는 이 파일의 상수이고 명령이 넘기는 것은 정규식을 거친 이름과 Secret뿐이다. 이름은 셸에 끼우지 않고 위치 인자로
// 넘긴다(sh -c '...' sh <인자>). 비밀번호는 stdin으로만 넘기고(-a·env는 ps에 보인다, restore.md 0.3), 거부 판정은 core 고정
// 정규식(exec signals)으로 받는다(민감 호출의 stderr 원문은 버린다).
import type { BotAccount, BotAccountLimit, BotAdminCommand, BotAdminReport, BotMethod, BotRead, BotWrite, HttpWrite, KubeRead, PgWrite, ValkeyCommand, ValkeyWrite, WorkerLane } from "./command";
import { ExecTimeout, why, type Exec, type Forward } from "./exec";
import { jsonParse } from "./intrinsics";
import { APP_NAME, BOT_METHOD_KEY, BOT_WORKER_FILE, fullMatch, publicHash } from "./names";
import { Secret, isSecret, revealSecret } from "./secret";

const NAME = /^[a-z0-9]([-a-z0-9]*[a-z0-9])?$/;
const PRIMARY = /^pg-[0-9]+$/;
const REQUEST_TIMEOUT = "--request-timeout=20s";

// rotate.md 3c 5와 같은 확인. 앱 역할·DB 이름은 $1(위치 인자)이다.
export const PG_PASSWORD_CHECK = 'IFS= read -r PGPASSWORD || true; export PGPASSWORD; exec psql "host=127.0.0.1 user=$1 dbname=$1 sslmode=require" -tAc "select 1"';
// restore.md 0.3 vk와 같다. 명령 단어는 "$@"로만 간다.
export const VALKEY_CLI = 'IFS= read -r REDISCLI_AUTH || true; export REDISCLI_AUTH; exec valkey-cli "$@"';

const VALKEY_WORDS: Record<ValkeyCommand, string[]> = {
  PING: ["PING"],
  DBSIZE: ["DBSIZE"],
  "CONFIG GET appendonly": ["CONFIG", "GET", "appendonly"],
  "CONFIG SET appendonly yes": ["CONFIG", "SET", "appendonly", "yes"],
  "INFO persistence": ["INFO", "persistence"],
};

// 복원 표식 키. id는 CLI 실행 id(소문자·숫자) 또는 손 런북 RUN(YYYYMMDD-HHMMSS-hex).
const MARKER_PREFIX = "homelab:restore:";
const MARKER_ID = /^[a-z0-9][a-z0-9-]{0,40}$/;

const PG_REJECTED = { rejected: /password authentication failed/ };
const VALKEY_REJECTED = { rejected: /WRONGPASS|NOAUTH/ };

function checkNs(ns: string): void {
  if (!NAME.test(ns) || ns.length > 63) throw new Error("namespace 이름 형식이 아니다");
}

function checkValkey(deployment: string): void {
  if (!NAME.test(deployment) || !deployment.endsWith("-valkey") || deployment.length > 63) throw new Error("Valkey Deployment 이름은 <앱>-valkey다");
}

// CNPG 공유 클러스터 pg의 현재 primary 파드(rotate.md 0절).
function primaryPod(k8s: KubeRead): string {
  const pod = k8s.get("cluster", "database", "pg")?.status?.currentPrimary;
  if (typeof pod !== "string" || !PRIMARY.test(pod)) throw new Error("CNPG pg의 currentPrimary를 읽지 못했다");
  return pod;
}

export function pgWrite(exec: Exec, k8s: KubeRead): PgWrite {
  return {
    passwordCheck(app, password) {
      if (!fullMatch(APP_NAME, app)) throw new Error("앱 이름 형식이 아니다");
      if (!isSecret(password)) throw new Error("비밀번호는 Secret이다");
      const pod = primaryPod(k8s);
      const r = exec(["kubectl", "-n", "database", "exec", "-i", pod, "-c", "postgres", REQUEST_TIMEOUT, "--", "sh", "-c", PG_PASSWORD_CHECK, "sh", app], { input: password, signals: PG_REJECTED });
      if (r.errKind === "timeout") throw new ExecTimeout(`${app} 로그인 확인: 시간 초과`);
      if (r.signals?.includes("rejected")) return "rejected";
      if (r.code === 0 && r.stdout.trim() === "1") return "accepted";
      throw new Error(`${app} 로그인 확인: ${why(r)}`);
    },
  };
}

export function valkeyWrite(exec: Exec, k8s: KubeRead, pollMs: number): ValkeyWrite {
  // <deployment>-auth Secret의 password. 값은 Secret으로만 들고 stdin으로 넘긴다.
  const authOf = (ns: string, deployment: string): Secret => {
    const r = exec(["kubectl", "-n", ns, "get", "secrets", `${deployment}-auth`, "-o", "json", REQUEST_TIMEOUT], { secretStdout: true });
    if (r.errKind === "timeout") throw new ExecTimeout(`${deployment}-auth: 시간 초과`);
    if (r.code !== 0 || !r.stdoutSecret) throw new Error(`${deployment}-auth: ${why(r)}`);
    const encoded = jsonParse(revealSecret(r.stdoutSecret)).data?.password;
    if (typeof encoded !== "string") throw new Error(`${deployment}-auth에 password가 없다`);
    return new Secret(Buffer.from(encoded, "base64").toString("utf8"));
  };
  const send = (ns: string, deployment: string, auth: Secret, words: string[]) =>
    exec(["kubectl", "-n", ns, "exec", "-i", `deploy/${deployment}`, REQUEST_TIMEOUT, "--", "sh", "-c", VALKEY_CLI, "sh", ...words], { input: auth, signals: VALKEY_REJECTED });
  const cli = (ns: string, deployment: string, cmd: ValkeyCommand): string => {
    checkNs(ns);
    checkValkey(deployment);
    const words = Object.hasOwn(VALKEY_WORDS, cmd) ? VALKEY_WORDS[cmd] : undefined;
    if (!words) throw new Error("Valkey 명령은 정해진 다섯만");
    const r = send(ns, deployment, authOf(ns, deployment), words);
    if (r.errKind === "timeout") throw new ExecTimeout(`valkey-cli ${cmd}: 시간 초과`);
    if (r.signals?.includes("rejected")) throw new Error(`valkey-cli ${cmd}: 인증이 거부됐다`);
    if (r.code !== 0) throw new Error(`valkey-cli ${cmd}: ${why(r)}`);
    return r.stdout;
  };
  return {
    cli,
    waitAof(ns, deployment, timeoutSec) {
      if (!Number.isInteger(timeoutSec) || timeoutSec < 1 || timeoutSec > 300) throw new Error("기다림은 1~300초다");
      const deadline = Date.now() + timeoutSec * 1000;
      for (;;) {
        const info = cli(ns, deployment, "INFO persistence");
        const field = (k: string) => new RegExp(`^${k}:(\\S+)`, "m").exec(info)?.[1];
        // 예약(aof_rewrite_scheduled:1)도 끝나지 않은 것이다. RDB 저장 중에 AOF를 켜면 Valkey 9.1.2는 첫 AOF 생성을 예약만 하고
        // 나머지 값은 끝난 것처럼 보인다(aof.c startAppendOnly). 그때 재시작하면 옛 AOF나 빈 데이터로 뜬다.
        // 값이 없으면(필드 이름이 바뀐 버전) 끝났다고 보지 않는다.
        if (field("aof_enabled") === "1" && field("aof_rewrite_in_progress") === "0" && field("aof_rewrite_scheduled") === "0" && field("aof_last_bgrewrite_status") === "ok") return true;
        if (Date.now() + pollMs > deadline) return false;
        Bun.sleepSync(pollMs);
      }
    },
    marker(ns, deployment, run, op) {
      checkNs(ns);
      checkValkey(deployment);
      if (!MARKER_ID.test(run)) throw new Error("복원 실행 id 형식이 아니다");
      const key = `${MARKER_PREFIX}${run}`;
      const words = op === "set" ? ["SET", key, run] : op === "exists" ? ["EXISTS", key] : op === "del" ? ["DEL", key] : undefined;
      if (!words) throw new Error("표식 키 작업은 set·exists·del만");
      const r = send(ns, deployment, authOf(ns, deployment), words);
      if (r.errKind === "timeout") throw new ExecTimeout(`valkey-cli ${words[0]}: 시간 초과`);
      if (r.signals?.includes("rejected")) throw new Error(`valkey-cli ${words[0]}: 인증이 거부됐다`);
      if (r.code !== 0) throw new Error(`valkey-cli ${words[0]}: ${why(r)}`);
      const out = r.stdout.trim();
      // valkey-cli는 오류도 exit 0으로 stdout에 낼 수 있다(ERR·NOPERM). 기대한 답이 아니면 실패다.
      if (op === "set") {
        if (out !== "OK") throw new Error(`valkey-cli SET: 답이 OK가 아니다`);
        return true;
      }
      if (op === "exists") {
        if (out !== "0" && out !== "1") throw new Error("valkey-cli EXISTS: 답이 0·1이 아니다");
        return out === "1";
      }
      if (out !== "0" && out !== "1") throw new Error("valkey-cli DEL: 답이 0·1이 아니다");
      return true;
    },
    markers(ns, deployment) {
      checkNs(ns);
      checkValkey(deployment);
      const r = send(ns, deployment, authOf(ns, deployment), ["--scan", "--pattern", `${MARKER_PREFIX}*`]);
      if (r.errKind === "timeout") throw new ExecTimeout("valkey-cli --scan: 시간 초과");
      if (r.signals?.includes("rejected")) throw new Error("valkey-cli --scan: 인증이 거부됐다");
      if (r.code !== 0) throw new Error(`valkey-cli --scan: ${why(r)}`);
      const ids: string[] = [];
      for (const line of r.stdout.split("\n").map((x) => x.trim()).filter(Boolean)) {
        // 오류 문구(ERR·NOPERM)나 꼴이 다른 키는 셀 수 없다.
        const id = line.startsWith(MARKER_PREFIX) ? line.slice(MARKER_PREFIX.length) : "";
        if (!MARKER_ID.test(id)) throw new Error("valkey-cli --scan: 표식 키 꼴이 아닌 답이 있다");
        ids.push(id);
      }
      return [...new Set(ids)];
    },
    authCheck(ns, deployment, password) {
      checkNs(ns);
      checkValkey(deployment);
      if (!isSecret(password)) throw new Error("비밀번호는 Secret이다");
      const r = send(ns, deployment, password, ["PING"]);
      if (r.errKind === "timeout") throw new ExecTimeout("Valkey 인증 확인: 시간 초과");
      if (r.signals?.includes("rejected")) return "rejected";
      if (r.code === 0 && r.stdout.trim() === "PONG") return "accepted";
      throw new Error(`Valkey 인증 확인: ${why(r)}`);
    },
  };
}

// 봇 관리 기능(homelab bot). 대상(ns·앱·컨테이너)과 진입점은 봇 계약이라 여기 고정한다(설계 C.8 봇 저장소, 봇 ARCHITECTURE §14
// "연결 지점"의 admin-main). 명령은 동작과 형식 검사를 거친 ID만 넘기고, 그것도 위치 인자로만 간다(셸 없음).
export const BOT_NS = "app-homelab-bot";
const BOT_APP = "homelab-bot";
export const BOT_ENTRY = ["node", "/app/dist/src/admin-main.js"];
const BOT_SCHEMA = "homelab-bot-admin/v1";
const BOT_UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const BOT_SNOWFLAKE = /^[1-9][0-9]{16,19}$/;
const BOT_RESULTS = new Set([
  "stopped", "already_stopped", "released", "not_stopped", "running_jobs", "status", "unsupported", "usage", "failed",
  "blocked", "already_blocked", "resumed", "not_releasable", "not_waiting", "emergency_stopped", "queue_full",
  "recorded", "accounts", "switched", "unknown_account",
]);
// 봇 계정 이름(봇 src/model-accounts.ts ACCOUNT_NAME와 같다). Infisical 폴더 이름 조각이자 지표 라벨 값이 된다.
const BOT_ACCOUNT = /^[a-z]([a-z0-9-]{0,30}[a-z0-9])?$/;
const BOT_TIME = /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$/;
const BOT_WORD = /^[a-z_]{1,32}$/;
const BOT_EXITS = new Set([0, 1, 3, 4, 64]);

function botWords(cmd: BotAdminCommand): string[] {
  const id = (re: RegExp, v: string) => {
    if (!re.test(v)) throw new Error("봇 관리 명령의 ID 형식이 아니다");
    return v;
  };
  switch (cmd.name) {
    case "emergency-stop":
    case "status":
      return [cmd.name];
    case "resume":
      return cmd.target === "emergency-stop" ? ["resume", "emergency-stop"] : ["resume", "job", id(BOT_UUID, cmd.job)];
    case "block":
      return ["block", id(BOT_SNOWFLAKE, cmd.user)];
    case "release":
      return ["release", id(BOT_UUID, cmd.job)];
    case "account":
      if (cmd.action === "list") return ["account", "list"];
      if ((cmd.action === "record" || cmd.action === "use") && (cmd.method === "subscription" || cmd.method === "api")) return ["account", cmd.action, id(BOT_ACCOUNT, cmd.account), cmd.method];
      break;
  }
  throw new Error("봇 관리 명령이 아니다");
}

const ready = (p: any) => (p?.status?.conditions ?? []).some((c: any) => c?.type === "Ready" && c?.status === "True");

// 봇 출력의 마지막 줄 JSON에서 결과 이름과 상태 값만 꺼낸다. 꼴이 다르면 원문 없이 던진다.
function botReport(stdout: string, exit: number): BotAdminReport {
  const fail = () => new Error(`봇 관리 진입점 출력이 정해진 꼴이 아니다(exit ${exit})`);
  if (!BOT_EXITS.has(exit)) throw fail();
  let doc: any;
  try {
    doc = jsonParse(stdout.trim().split("\n").at(-1) ?? "");
  } catch {
    throw fail();
  }
  if (doc === null || typeof doc !== "object" || doc.schema !== BOT_SCHEMA || typeof doc.result !== "string" || !BOT_RESULTS.has(doc.result)) throw fail();
  const extra = accountParts(doc);
  if (extra === null) throw fail();
  const s = doc.state;
  if (s === undefined) return { exit, result: doc.result, state: null, ...extra };
  const flags = ["emergency", "paused", "executionPending"].every((k) => typeof s?.[k] === "boolean");
  const lane = s?.taskLaneClosed === null || (typeof s?.taskLaneClosed === "string" && /^[a-z_]{1,32}$/.test(s.taskLaneClosed));
  if (!flags || !lane) throw fail();
  return { exit, result: doc.result, state: { emergency: s.emergency, paused: s.paused, executionPending: s.executionPending, taskLaneClosed: s.taskLaneClosed }, ...extra };
}

// 계정 결과 칸(accounts·paused·switch)을 정해진 꼴로만 옮긴다. 모르는 칸은 버리고, 꼴이 다르면 null(출력 거부).
// 봇 출력에는 값이 없지만, 꼴이 다른 출력(예 다른 판의 진입점)이 문자열을 실어 와도 그대로 보이지 않게 한 칸씩 본다.
function accountParts(doc: any): Pick<BotAdminReport, "accounts" | "paused" | "switch"> | null {
  const out: Pick<BotAdminReport, "accounts" | "paused" | "switch"> = {};
  const count = (v: unknown) => Number.isInteger(v) && (v as number) >= 0 && (v as number) < 1_000_000;
  const time = (v: unknown) => v === null || (typeof v === "string" && BOT_TIME.test(v));
  const word = (v: unknown) => v === null || (typeof v === "string" && BOT_WORD.test(v));
  if (doc.accounts !== undefined) {
    if (!Array.isArray(doc.accounts) || doc.accounts.length > 100) return null;
    const accounts: BotAccount[] = [];
    for (const a of doc.accounts) {
      if (typeof a?.name !== "string" || !BOT_ACCOUNT.test(a.name) || (a.method !== "subscription" && a.method !== "api") || typeof a.current !== "boolean") return null;
      if (!time(a.issuedAt) || !time(a.expiresAt)) return null;
      const l = a.limit;
      let limit: BotAccountLimit | null = null;
      if (l !== null) {
        const utilization = l?.utilization === null || (typeof l?.utilization === "number" && l.utilization >= 0 && l.utilization <= 10);
        if (!word(l?.status) || !word(l?.rateLimitType) || !utilization || !time(l?.resetsAt) || !time(l?.observedAt)) return null;
        limit = { status: l.status, rateLimitType: l.rateLimitType, utilization: l.utilization, resetsAt: l.resetsAt, observedAt: l.observedAt };
      }
      accounts.push({ name: a.name, method: a.method, current: a.current, issuedAt: a.issuedAt, expiresAt: a.expiresAt, limit });
    }
    out.accounts = accounts;
  }
  if (doc.paused !== undefined) {
    const p = doc.paused;
    if (!count(p?.rate_limit) || !count(p?.auth_expired) || !count(p?.billing)) return null;
    out.paused = { rate_limit: p.rate_limit, auth_expired: p.auth_expired, billing: p.billing };
  }
  if (doc.switch !== undefined) {
    const s = doc.switch;
    if (!count(s?.resumed) || !count(s?.waiting) || ![null, "emergency_stopped", "queue_full"].includes(s?.held)) return null;
    out.switch = { resumed: s.resumed, waiting: s.waiting, held: s.held };
  }
  return out;
}

// 작업자 자격 파일(rotate.md 3e 4단계). ns·Deployment·컨테이너·경로는 sandbox 차트의 고정 값이다.
const WORKER_NS = "sandbox";
const WORKER_DEPLOY: Record<WorkerLane, string> = { chat: "worker", task: "worker-task" };
const WORKER_DIR = "/run/worker-credential";
const workerPath = (file: string) => `${WORKER_DIR}/${file}`;
const MARKER_PATH = workerPath(BOT_METHOD_KEY);
const HASH12 = /^[0-9a-f]{12}$/;
// 그 방식의 자격 파일과 방식 표시 파일을 함께 본다. 방식 표시 파일이 없으면 sha256sum이 그 줄만 빼고 1로 끝난다(아래에서 줄로 읽는다).
export const workerHashArgv = (lane: WorkerLane, method: BotMethod) =>
  ["kubectl", "-n", WORKER_NS, "exec", `deploy/${WORKER_DEPLOY[lane]}`, "-c", "worker", REQUEST_TIMEOUT, "--", "sha256sum", workerPath(BOT_WORKER_FILE[method]), MARKER_PATH];
// sha256sum 출력에서 경로별 앞 12자.
function sums(stdout: string): Map<string, string> {
  const out = new Map<string, string>();
  for (const line of stdout.split("\n")) {
    const m = /^([0-9a-f]{64}) {2}(\S+)$/.exec(line);
    if (m) out.set(m[2]!, m[1]!.slice(0, 12));
  }
  return out;
}

export function botRead(k8s: KubeRead): BotRead {
  return {
    pod() {
      const live = k8s.list("pod", BOT_NS, `homelab.ukyi.app/app=${BOT_APP}`).filter(
        (p) =>
          p?.metadata?.namespace === BOT_NS &&
          p?.metadata?.labels?.["homelab.ukyi.app/app"] === BOT_APP &&
          p?.metadata?.labels?.["homelab.ukyi.app/role"] === undefined &&
          (p?.metadata?.ownerReferences ?? []).some((o: any) => o?.kind === "ReplicaSet") &&
          p?.metadata?.deletionTimestamp === undefined &&
          p?.status?.phase === "Running" &&
          ready(p),
      );
      if (live.length !== 1) throw new Error(`${BOT_NS}에 Running·Ready인 봇 게시 서버 파드가 ${live.length}개다(하나여야 실행한다)`);
      const name = live[0].metadata.name;
      if (typeof name !== "string" || !NAME.test(name) || name.length > 253) throw new Error("봇 파드 이름 형식이 아니다");
      return name;
    },
    argv(pod, cmd) {
      if (!NAME.test(pod) || pod.length > 253) throw new Error("봇 파드 이름 형식이 아니다");
      // --request-timeout은 -- 앞에 둔다(뒤에 두면 node의 인자가 된다). 컨테이너 app은 공유 차트의 앱 컨테이너 이름이다.
      return ["kubectl", "-n", BOT_NS, "exec", pod, "-c", "app", REQUEST_TIMEOUT, "--", ...BOT_ENTRY, ...botWords(cmd)];
    },
  };
}

export function botWrite(exec: Exec, k8s: KubeRead, pollMs = 2_000): BotWrite {
  const read = botRead(k8s);
  return {
    ...read,
    admin(cmd) {
      const argv = read.argv(read.pod(), cmd);
      // 진입점은 DB 트랜잭션 하나로 끝난다. 답이 없으면 결과 미상으로 엔진이 다시 읽는다(재시도하지 않는다).
      const r = exec(argv, { timeoutMs: 60_000 });
      if (r.errKind === "timeout") throw new ExecTimeout("봇 관리 진입점: 시간 초과(결과 미상)");
      // 출력이 없으면 진입점까지 가지 못한 것이다(kubectl 오류). 진입점의 stderr에는 오류 이름·코드만 있다.
      if (r.errKind || r.code === null || (r.code !== 0 && r.stdout.trim() === "")) throw new Error(`봇 관리 진입점: ${why(r)}`);
      return botReport(r.stdout, r.code);
    },
    waitWorkerCredentials(want, timeoutSec, method) {
      if (!Number.isInteger(timeoutSec) || timeoutSec < 1 || timeoutSec > 300) throw new Error("기다림은 1~300초다");
      if (method !== "subscription" && method !== "api") throw new Error("방식은 subscription·api만");
      const lanes = Object.keys(WORKER_DEPLOY) as WorkerLane[];
      for (const lane of lanes) if (!HASH12.test(want[lane] ?? "")) throw new Error("작업자 자격 지문은 sha256 앞 12자다");
      const seen: Record<WorkerLane, boolean> = { chat: false, task: false };
      const deadline = Date.now() + timeoutSec * 1000;
      const marker = publicHash(method);
      for (;;) {
        for (const lane of lanes) {
          if (seen[lane]) continue;
          // 실패(파드 교체 중, worker-task의 exec가 정리 sweep에 죽음)는 기다림의 일부다. 다음 바퀴에 다시 본다.
          // 종료 코드는 보지 않는다. 방식 표시 파일이 없으면(sandbox 배포 전 Secret) sha256sum이 1로 끝나도 자격 줄은 있다.
          const r = exec(workerHashArgv(lane, method), { timeoutMs: 30_000 });
          if (r.errKind || r.code === null) continue;
          const got = sums(r.stdout);
          const shown = got.get(MARKER_PATH);
          const markerOk = method === "api" ? shown === marker : shown === undefined || shown === marker;
          if (got.get(workerPath(BOT_WORKER_FILE[method])) === want[lane] && markerOk) seen[lane] = true;
        }
        if (lanes.every((lane) => seen[lane]) || Date.now() + pollMs > deadline) return seen;
        Bun.sleepSync(pollMs);
      }
    },
  };
}

const HEALTH = new Set(["/healthz", "/healthz/db", "/healthz/cache"]);

export function httpWrite(forward: Forward): HttpWrite {
  return {
    async appStatus(ns, deployment, port, path) {
      checkNs(ns);
      if (!NAME.test(deployment)) throw new Error("Deployment 이름 형식이 아니다");
      if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error("포트 범위가 아니다");
      if (!HEALTH.has(path)) throw new Error("헬스 경로는 /healthz·/healthz/db·/healthz/cache만");
      return forward(["-n", ns, "port-forward", `deploy/${deployment}`, `:${port}`, REQUEST_TIMEOUT], path);
    },
  };
}
