// homelab cache rotate <app> [--finish]: Valkey 비밀번호 회전(설계 C.6.5, rotate.md 3d). 캐시(앱 차트)·영속(데이터 차트) 둘 다.
//
// db rotate와 같은 모양이다(기록은 Infisical PASSWORD_PREVIOUS, --finish가 다시 확인한 뒤 지운다). 도우미 파일은 명령마다
// 따로라(정적 시험의 소유 규칙) 비슷한 코드가 rotate-db.ts에도 있다.
// 함정: 서버는 시작 때 ACL 파일을 만들어 다시 띄워야 새 값이 적용된다. 그동안(수 초) 앱은 Valkey 오류를 낸다.
// 캐시 Valkey는 다시 띄우면 비워지고(emptyDir), 영속은 AOF everysec라 약 1초를 잃는다. 다시 띄우기는 rollout(Deployment 업데이트)로만
// 한다. Recreate의 "옛 파드가 끝난 뒤 새 파드" 보장은 Deployment 업데이트에만 있다(restore.md 1절 5).
import { defineCommand, type Observation, type ReadCtx, type Step, type WriteCtx } from "../core/command";
import { APP_NAME, newRunId } from "../core/names";
import { parseYaml } from "../core/values";

const PASSWORD = "PASSWORD";
const PREVIOUS = "PASSWORD_PREVIOUS";
const WAIT = 60;

// 엔진은 Plan.next가 undefined를 내면 기본 다음 행동을 쓴다(engine.ts finish). 타입은 string | null이라 맞춰 둔다.
const KEEP = undefined as unknown as string | null;

const same = (detail: string): Observation => ({ state: "same", action: "none", detail });
const NOT_YET: Observation = { state: "missing", action: "update", detail: "새 값이 생긴 뒤 진행" };

type Names = { app: string; folder: string; ns: string; server: string; auth: string; url: string };

function namesOf(app: string): Names {
  return { app, folder: `/apps/${app}/valkey`, ns: `app-${app}`, server: `${app}-valkey`, auth: `${app}-valkey-auth`, url: `${app}-valkey-url` };
}

function values(ctx: ReadCtx | WriteCtx, path: string): any | null {
  const text = ctx.repo.readFile(path);
  return text === null ? null : parseYaml(text);
}

// 캐시는 앱 차트(cache.enabled), 영속은 데이터 차트(valkey.persistent). 둘 다 이름은 <app>-valkey·<app>-valkey-auth·<app>-valkey-url이다.
function kindOf(ctx: ReadCtx | WriteCtx, app: string): "cache" | "persistent" | null {
  if (values(ctx, `data/${app}/values.yaml`)?.valkey?.persistent === true) return "persistent";
  if (values(ctx, `apps/${app}/values.yaml`)?.cache?.enabled === true) return "cache";
  return null;
}

function appPort(ctx: ReadCtx | WriteCtx, app: string): number {
  const port = values(ctx, `apps/${app}/values.yaml`)?.port;
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error(`apps/${app}/values.yaml에 port가 없다`);
  return port;
}

function phase(ctx: ReadCtx, n: Names): { prev: string | null; cur: string | null; pending: boolean } {
  const prev = ctx.infisical.valueHash(n.folder, PREVIOUS);
  const cur = ctx.infisical.valueHash(n.folder, PASSWORD);
  return { prev, cur, pending: prev === null || cur === prev };
}

function current(ctx: ReadCtx, n: Names, deployment: string): boolean {
  const p = ctx.k8s.podSecretsCurrent(n.ns, deployment);
  return p.current && p.rolledOut;
}

function urlState(ctx: ReadCtx, n: Names): boolean | null {
  const v = ctx.infisical.getValue(n.folder, PASSWORD);
  if (!v) throw new Error(`Infisical ${n.folder}/${PASSWORD}가 없다`);
  return ctx.k8s.secretEmbeds(n.ns, n.url, "VALKEY_URL", v);
}

function secret(w: WriteCtx, n: Names, key: string) {
  const v = w.infisical.getValue(n.folder, key);
  if (!v) throw new Error(`Infisical ${n.folder}/${key}를 읽지 못했다`);
  return v;
}

// 영속 Valkey의 다음 백업이 새 값으로 도는지(rotate.md 3d 4). CronJob에서 수동 Job 하나를 만들어 끝나기를 기다리고 지운다.
async function backupCheck(w: WriteCtx, n: Names): Promise<void> {
  const run = newRunId();
  const job = `backup-${run}-${run.slice(-4)}`;
  w.k8s.createJobFromCronJob(n.ns, `${n.app}-valkey-backup`, job, run);
  const ok = w.k8s.waitCondition("job", n.ns, { name: job }, "complete", 600);
  const log = ok ? w.k8s.logs(n.ns, { job }, { container: "upload", tail: 20 }) : "";
  // 실패한 Job은 지우지 않는다(로그를 사람이 본다). 성공했으면 이 실행의 것만 지운다.
  if (!ok || !/올림: /.test(log)) throw new Error(`수동 백업 Job ${job}이 끝나지 않았다(kubectl -n ${n.ns} logs job/${job} --all-containers)`);
  w.k8s.deleteRestoreObjects(n.ns, run);
}

async function verifyLive(w: WriteCtx, n: Names, withBackup: boolean): Promise<void> {
  const cur = secret(w, n, PASSWORD);
  const prev = secret(w, n, PREVIOUS);
  if (w.valkey.authCheck(n.ns, n.server, cur) !== "accepted") throw new Error("새 비밀번호로 Valkey에 인증되지 않는다");
  if (w.valkey.authCheck(n.ns, n.server, prev) !== "rejected") throw new Error("옛 비밀번호로도 Valkey에 인증된다(서버가 다시 뜨지 않았다)");
  const code = await w.http.appStatus(n.ns, n.app, appPort(w, n.app), "/healthz/cache");
  if (code !== 200) throw new Error(`앱 /healthz/cache가 ${code}다`);
  if (withBackup) await backupCheck(w, n);
}

function registered(n: Names): Step {
  return {
    id: "registered",
    target: `Valkey ${n.app}`,
    async read(ctx) {
      const kind = kindOf(ctx, n.app);
      if (!kind) return { state: "missing", action: "none", detail: "캐시(apps cache.enabled)·영속(data valkey.persistent) Valkey가 없다", next: `homelab cache add ${n.app}` };
      if (values(ctx, `apps/${n.app}/values.yaml`)?.uses?.valkey !== true) return { state: "missing", action: "none", detail: `apps/${n.app}에 uses.valkey가 없다`, next: `homelab cache add ${n.app}` };
      appPort(ctx, n.app);
      if (!ctx.infisical.has(n.folder, PASSWORD)) return { state: "missing", action: "none", detail: `Infisical ${n.folder}/${PASSWORD} 없음`, next: `homelab cache add ${n.app}` };
      return same(kind === "cache" ? "캐시 Valkey(다시 띄우면 비워진다)" : "영속 Valkey(AOF everysec, 재시작 손실 약 1초)");
    },
  };
}

function syncStep(n: Names, id: string, name: string, key: string, check: (ctx: ReadCtx) => boolean): Step {
  return {
    id,
    target: `Secret ${n.ns}/${name}`,
    async read(ctx) {
      if (phase(ctx, n).pending) return NOT_YET;
      return check(ctx) ? same("새 값") : { state: "differs", action: "update", detail: "옛 값 → ExternalSecret 즉시 동기화" };
    },
    async apply(w) {
      w.k8s.forceSync(n.ns, name, { waitSec: WAIT });
      const want = key === "password" ? { hash: w.infisical.valueHash(n.folder, PASSWORD) ?? "" } : { embeds: secret(w, n, PASSWORD) };
      if (!w.k8s.waitSecret(n.ns, name, key, want, WAIT)) throw new Error(`${WAIT}초 안에 ${name}에 새 값이 들어오지 않았다`);
    },
  };
}

function startSteps(n: Names): Step[] {
  return [
    registered(n),
    {
      id: "baseline",
      target: "회전 전 상태",
      async read(ctx) {
        if (ctx.infisical.valueHash(n.folder, PREVIOUS) !== null) return same("회전 진행 중(PASSWORD_PREVIOUS 있음)");
        const cur = ctx.infisical.valueHash(n.folder, PASSWORD);
        if (cur !== null && cur === ctx.k8s.secretHash(n.ns, n.auth, "password")) return same("Infisical과 서버 Secret이 같다");
        return { state: "differs", action: "none", detail: "Infisical PASSWORD와 서버 Secret이 다르다(동기화되지 않은 변경)", next: "rotate.md 3d 2·3단계로 먼저 맞춘다" };
      },
    },
    {
      id: "previous",
      target: `Infisical ${n.folder}/${PREVIOUS}`,
      async read(ctx) {
        return ctx.infisical.valueHash(n.folder, PREVIOUS) !== null ? same("있음(옛 값 보존)") : { state: "missing", action: "create", detail: "없음 → 지금 PASSWORD를 옮겨 둔다" };
      },
      async apply(w) {
        w.infisical.setValue(n.folder, PREVIOUS, secret(w, n, PASSWORD));
      },
    },
    {
      id: "password",
      target: `Infisical ${n.folder}/${PASSWORD}`,
      async read(ctx) {
        const p = phase(ctx, n);
        if (p.prev === null) return { state: "missing", action: "update", detail: "새 값 생성(영숫자 40자, 옛 값을 옮긴 뒤)" };
        return p.pending ? { state: "differs", action: "update", detail: "옛 값 그대로 → 새 값 생성(영숫자 40자)" } : same("새 값 있음");
      },
      async apply(w) {
        w.infisical.setValue(n.folder, PASSWORD, w.generatePassword());
      },
    },
    syncStep(n, "auth-secret", n.auth, "password", (ctx) => ctx.k8s.secretHash(n.ns, n.auth, "password") === phase(ctx, n).cur),
    syncStep(n, "url-secret", n.url, "VALKEY_URL", (ctx) => urlState(ctx, n) === true),
    {
      id: "server-restart",
      target: `Deployment ${n.ns}/${n.server}`,
      async read(ctx) {
        if (phase(ctx, n).pending) return NOT_YET;
        return current(ctx, n, n.server) ? same("새 Secret으로 떠 있다") : { state: "differs", action: "update", detail: "서버 다시 띄움 → 새 값 인증 확인" };
      },
      async apply(w) {
        w.k8s.restartForSecrets(n.ns, n.server);
        if (!w.k8s.rolloutStatus(n.ns, n.server, 300)) throw new Error("Valkey rollout이 300초 안에 끝나지 않았다");
        if (w.valkey.authCheck(n.ns, n.server, secret(w, n, PASSWORD)) !== "accepted") throw new Error("새 비밀번호로 Valkey에 인증되지 않는다");
      },
    },
    {
      id: "app-restart",
      target: `Deployment ${n.ns}/${n.app}`,
      async read(ctx) {
        if (phase(ctx, n).pending) return NOT_YET;
        return current(ctx, n, n.app) ? same("새 Secret으로 떠 있다") : { state: "differs", action: "update", detail: "앱 다시 띄움 → /healthz/cache 확인" };
      },
      async apply(w) {
        w.k8s.restartForSecrets(n.ns, n.app);
        if (!w.k8s.rolloutStatus(n.ns, n.app, 300)) throw new Error("앱 rollout이 300초 안에 끝나지 않았다");
        // 여기서 실패하면 재실행은 이 단계를 건너뛴다. 같은 확인을 --finish가 PREVIOUS를 지우기 전에 다시 한다.
        await verifyLive(w, n, false);
      },
    },
  ];
}

function finishSteps(n: Names): Step[] {
  return [
    registered(n),
    {
      id: "consistent",
      target: "회전 결과",
      async read(ctx) {
        const p = phase(ctx, n);
        if (p.prev === null) return same("회전 기록 없음(PASSWORD_PREVIOUS 없음)");
        const next = `homelab cache rotate ${n.app} --apply`;
        if (p.pending) return { state: "differs", action: "none", detail: "새 값이 아직 없다", next };
        if (ctx.k8s.secretHash(n.ns, n.auth, "password") !== p.cur || urlState(ctx, n) !== true) return { state: "differs", action: "none", detail: "Secret이 새 값이 아니다", next };
        if (!current(ctx, n, n.server) || !current(ctx, n, n.app)) return { state: "differs", action: "none", detail: "서버·앱이 새 Secret으로 다시 뜨지 않았다", next };
        return same("새 값이 서버·앱까지 반영됨");
      },
    },
    {
      id: "previous-removed",
      target: `Infisical ${n.folder}/${PREVIOUS}`,
      async read(ctx) {
        if (ctx.infisical.valueHash(n.folder, PREVIOUS) === null) return same("없음");
        const backup = kindOf(ctx, n.app) === "persistent" ? ", 수동 백업 Job" : "";
        return { state: "differs", action: "delete", detail: `있음 → 새 값 인증·옛 값 거부·/healthz/cache${backup}을 다시 본 뒤 지움` };
      },
      async apply(w) {
        await verifyLive(w, n, kindOf(w, n.app) === "persistent");
        w.infisical.removeKey(n.folder, PREVIOUS);
      },
    },
  ];
}

export default defineCommand({
  path: ["cache", "rotate"],
  summary: "Valkey 비밀번호 회전(C.6.5). --finish로 옛 값 정리",
  kind: "change",
  args: [{ name: "app", required: true, help: "앱 이름", pattern: APP_NAME }],
  flags: [{ name: "finish", kind: "bool", help: "회전을 끝낸다: 다시 확인한 뒤 PASSWORD_PREVIOUS를 지운다" }],
  async run(ctx, input) {
    const app = input.args.app as string;
    const n = namesOf(app);
    const finish = input.flags.finish === true;
    return ctx.engine({
      command: "cache rotate",
      app,
      steps: finish ? finishSteps(n) : startSteps(n),
      notes: finish
        ? ["옛 값은 지우면 되돌릴 수 없다(Infisical Free에는 버전 이력이 없다). 지우기 직전에 다시 확인한다."]
        : ["서버를 다시 띄우는 동안(수 초) 앱은 Valkey 오류를 낸다. 캐시 Valkey는 비워지고 영속은 약 1초를 잃는다."],
      next: finish ? undefined : (status) => (status === "done" || status === "same" ? `homelab cache rotate ${app} --finish` : KEEP),
    });
  },
});
