// 파드 안 작업(쓰기 문맥만, 03 D3·D6·D7). kubectl exec·port-forward는 쓰기로 판정되어 plan에서 돌지 않는다(AC-2).
// 셸 텍스트는 이 파일의 상수이고 명령이 넘기는 것은 정규식을 거친 이름과 Secret뿐이다. 이름은 셸에 끼우지 않고 위치 인자로
// 넘긴다(sh -c '...' sh <인자>). 비밀번호는 stdin으로만 넘기고(-a·env는 ps에 보인다, restore.md 0.3), 거부 판정은 core 고정
// 정규식(exec signals)으로 받는다(민감 호출의 stderr 원문은 버린다).
import type { HttpWrite, KubeRead, PgWrite, ValkeyCommand, ValkeyWrite } from "./command";
import { ExecTimeout, why, type Exec, type Forward } from "./exec";
import { jsonParse } from "./intrinsics";
import { APP_NAME, fullMatch } from "./names";
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
        // 나머지 값은 끝난 것처럼 보인다(aof.c startAppendOnly). 그때 재시작하면 옛 AOF나 빈 데이터로 뜬다(#889 r1 P1-1).
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
