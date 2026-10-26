// homelab db rotate <app> [--finish]: 앱 DB 비밀번호 회전(설계 C.6.5, rotate.md 3c, G 시나리오 8).
//
// 상태 저장소가 없어 Infisical의 PASSWORD_PREVIOUS가 "회전 중" 기록이다. 시작(기본)은 옛 값을 PREVIOUS로 옮기고 새 값을
// 만들어 역할 Secret → CNPG ALTER ROLE → 앱 연결 Secret → 앱 재시작까지 하고 PREVIOUS를 남긴다. 그래서 끝난 뒤 다시
// 쳐도 모든 단계가 same이다. PREVIOUS는 --finish가 지우기 직전에 헬스·새 값 접속·옛 값 거부를 다시 보고 지운다
// (끝난 회전과 처음 회전은 클러스터 상태로 구별할 수 없어, 기록을 지우는 일을 따로 둔다. REPORT-ops L2).
// 함정: 역할 Secret 동기화부터 앱 재시작까지 옛 값으로 새 연결을 여는 파드는 실패한다(T11 약 17~20초, 이미 열린 연결은 유지, U17).
import { defineCommand, type Observation, type ReadCtx, type Step, type WriteCtx } from "../core/command";
import { APP_NAME } from "../core/names";
import { parseYaml } from "../core/values";

const PASSWORD = "PASSWORD";
const PREVIOUS = "PASSWORD_PREVIOUS";
const WAIT = 60;

// 엔진은 Plan.next가 undefined를 내면 기본 다음 행동을 쓴다(engine.ts finish). 타입은 string | null이라 맞춰 둔다.
const KEEP = undefined as unknown as string | null;

const same = (detail: string): Observation => ({ state: "same", action: "none", detail });

type Names = { app: string; folder: string; appNs: string; roleSecret: string; dbSecret: string };

function namesOf(app: string): Names {
  return { app, folder: `/apps/${app}/postgres`, appNs: `app-${app}`, roleSecret: `pg-role-${app}`, dbSecret: `${app}-db` };
}

function values(ctx: ReadCtx | WriteCtx, path: string): any | null {
  const text = ctx.repo.readFile(path);
  return text === null ? null : parseYaml(text);
}

function appPort(ctx: ReadCtx | WriteCtx, app: string): number {
  const port = values(ctx, `apps/${app}/values.yaml`)?.port;
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error(`apps/${app}/values.yaml에 port가 없다`);
  return port;
}

// 회전이 어디까지 왔는지. prev가 없으면 아직 시작 전, cur = prev면 새 값을 만들기 전이다.
function phase(ctx: ReadCtx, n: Names): { prev: string | null; cur: string | null; pending: boolean } {
  const prev = ctx.infisical.valueHash(n.folder, PREVIOUS);
  const cur = ctx.infisical.valueHash(n.folder, PASSWORD);
  return { prev, cur, pending: prev === null || cur === prev };
}

const NOT_YET: Observation = { state: "missing", action: "update", detail: "새 값이 생긴 뒤 진행" };

function roleState(ctx: ReadCtx, n: Names): { ok: boolean; detail: string } {
  const role = ctx.k8s.get("databaserole", "database", n.app);
  if (!role) throw new Error(`DatabaseRole database/${n.app}이 없다`);
  const rv = ctx.k8s.secretExists("database", n.roleSecret).resourceVersion;
  const applied = role.status?.applied === true;
  const synced = rv !== null && String(role.status?.secretResourceVersion ?? "") === rv;
  if (applied && synced) return { ok: true, detail: "applied, secretResourceVersion = 역할 Secret" };
  const msg = typeof role.status?.message === "string" ? role.status.message.replace(/[^\x20-\x7e가-힣]/g, "?").slice(0, 120) : "";
  return { ok: false, detail: `CNPG 적용 대기(applied ${applied}, 버전 ${synced ? "같음" : "다름"}${msg ? `, ${msg}` : ""})` };
}

function dbUrlState(ctx: ReadCtx, n: Names): boolean | null {
  const v = ctx.infisical.getValue(n.folder, PASSWORD);
  if (!v) throw new Error(`Infisical ${n.folder}/${PASSWORD}가 없다`);
  return ctx.k8s.secretEmbeds(n.appNs, n.dbSecret, "DATABASE_URL", v);
}

function deployCurrent(ctx: ReadCtx, n: Names): boolean {
  const p = ctx.k8s.podSecretsCurrent(n.appNs, n.app);
  return p.current && p.rolledOut;
}

// 지우기 직전(--finish)과 재시작 직후의 실제 확인. 헬스 200, 새 값 접속, 옛 값 거부(시나리오 8).
async function verifyLive(w: WriteCtx, n: Names): Promise<void> {
  const code = await w.http.appStatus(n.appNs, n.app, appPort(w, n.app), "/healthz/db");
  if (code !== 200) throw new Error(`앱 /healthz/db가 ${code}다`);
  const cur = w.infisical.getValue(n.folder, PASSWORD);
  const prev = w.infisical.getValue(n.folder, PREVIOUS);
  if (!cur || !prev) throw new Error("Infisical PASSWORD·PASSWORD_PREVIOUS를 읽지 못했다");
  if (w.pg.passwordCheck(n.app, cur) !== "accepted") throw new Error("새 비밀번호로 접속되지 않는다");
  if (w.pg.passwordCheck(n.app, prev) !== "rejected") throw new Error("옛 비밀번호로도 접속된다(ALTER ROLE이 적용되지 않았다)");
}

function registered(n: Names): Step {
  return {
    id: "registered",
    target: `postgres ${n.app}`,
    async read(ctx) {
      if (values(ctx, `data/${n.app}/values.yaml`)?.postgres?.enabled !== true) return { state: "missing", action: "none", detail: `data/${n.app}에 postgres가 없다`, next: `homelab db add ${n.app}` };
      if (values(ctx, `apps/${n.app}/values.yaml`)?.uses?.postgres !== true) return { state: "missing", action: "none", detail: `apps/${n.app}에 uses.postgres가 없다`, next: `homelab db add ${n.app}` };
      appPort(ctx, n.app);
      if (!ctx.infisical.has(n.folder, PASSWORD)) return { state: "missing", action: "none", detail: `Infisical ${n.folder}/${PASSWORD} 없음`, next: `homelab db add ${n.app}` };
      if (!ctx.k8s.get("databaserole", "database", n.app)) return { state: "missing", action: "none", detail: "DatabaseRole 없음(데이터 Application 동기화 전)", next: `homelab status ${n.app}` };
      return same("등록됨");
    },
  };
}

function startSteps(n: Names): Step[] {
  return [
    registered(n),
    {
      id: "baseline",
      target: "회전 전 상태",
      // PREVIOUS가 실제 DB의 옛 값이어야 5단계(옛 값 거부)가 뜻이 있다. 어긋난 채 시작하지 않는다.
      async read(ctx) {
        if (ctx.infisical.valueHash(n.folder, PREVIOUS) !== null) return same("회전 진행 중(PASSWORD_PREVIOUS 있음)");
        const cur = ctx.infisical.valueHash(n.folder, PASSWORD);
        if (cur !== null && cur === ctx.k8s.secretHash("database", n.roleSecret, "password")) return same("Infisical과 역할 Secret이 같다");
        return { state: "differs", action: "none", detail: "Infisical PASSWORD와 역할 Secret이 다르다(동기화되지 않은 변경)", next: "rotate.md 3c 2·4단계로 먼저 맞춘다" };
      },
    },
    {
      id: "previous",
      target: `Infisical ${n.folder}/${PREVIOUS}`,
      async read(ctx) {
        return ctx.infisical.valueHash(n.folder, PREVIOUS) !== null ? same("있음(옛 값 보존)") : { state: "missing", action: "create", detail: "없음 → 지금 PASSWORD를 옮겨 둔다" };
      },
      async apply(w) {
        const v = w.infisical.getValue(n.folder, PASSWORD);
        if (!v) throw new Error(`Infisical ${n.folder}/${PASSWORD}가 없다`);
        w.infisical.setValue(n.folder, PREVIOUS, v);
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
    {
      id: "role-secret",
      target: `Secret database/${n.roleSecret}`,
      async read(ctx) {
        const p = phase(ctx, n);
        if (p.pending) return NOT_YET;
        return ctx.k8s.secretHash("database", n.roleSecret, "password") === p.cur ? same("새 값과 같다") : { state: "differs", action: "update", detail: "옛 값 → ExternalSecret 즉시 동기화" };
      },
      async apply(w) {
        const cur = w.infisical.valueHash(n.folder, PASSWORD);
        if (cur === null) throw new Error(`Infisical ${n.folder}/${PASSWORD}가 없다`);
        w.k8s.forceSync("database", n.roleSecret, { waitSec: WAIT });
        if (!w.k8s.waitSecret("database", n.roleSecret, "password", { hash: cur }, WAIT)) throw new Error(`${WAIT}초 안에 역할 Secret에 새 값이 들어오지 않았다`);
      },
    },
    {
      id: "role-applied",
      target: `DatabaseRole database/${n.app}`,
      async read(ctx) {
        if (phase(ctx, n).pending) return NOT_YET;
        const s = roleState(ctx, n);
        return s.ok ? same(s.detail) : { state: "differs", action: "update", detail: s.detail };
      },
      // 쓰기 없음. CNPG가 Secret 변경을 보고 ALTER ROLE 하기를 기다린다(cnpg.io/reload, rotate.md 3c 2).
      async apply(w) {
        const rv = w.k8s.secretExists("database", n.roleSecret).resourceVersion;
        if (rv === null) throw new Error(`역할 Secret ${n.roleSecret}의 버전을 읽지 못했다`);
        if (!w.k8s.waitFor("databaserole", "database", n.app, "{.status.secretResourceVersion}", rv, 120)) throw new Error("120초 안에 CNPG가 새 비밀번호를 적용하지 않았다");
      },
    },
    {
      id: "app-secret",
      target: `Secret ${n.appNs}/${n.dbSecret}`,
      async read(ctx) {
        if (phase(ctx, n).pending) return NOT_YET;
        return dbUrlState(ctx, n) === true ? same("DATABASE_URL이 새 값") : { state: "differs", action: "update", detail: "옛 값 → ExternalSecret 즉시 동기화" };
      },
      async apply(w) {
        const v = w.infisical.getValue(n.folder, PASSWORD);
        if (!v) throw new Error(`Infisical ${n.folder}/${PASSWORD}가 없다`);
        w.k8s.forceSync(n.appNs, n.dbSecret, { waitSec: WAIT });
        if (!w.k8s.waitSecret(n.appNs, n.dbSecret, "DATABASE_URL", { embeds: v }, WAIT)) throw new Error(`${WAIT}초 안에 앱 연결 Secret에 새 값이 들어오지 않았다`);
      },
    },
    {
      id: "app-restart",
      target: `Deployment ${n.appNs}/${n.app}`,
      async read(ctx) {
        if (phase(ctx, n).pending) return NOT_YET;
        return deployCurrent(ctx, n) ? same("새 Secret으로 떠 있다") : { state: "differs", action: "update", detail: "다시 띄움 → /healthz/db, 새 값 접속, 옛 값 거부 확인" };
      },
      async apply(w) {
        w.k8s.restartForSecrets(n.appNs, n.app);
        if (!w.k8s.rolloutStatus(n.appNs, n.app, 300)) throw new Error("앱 rollout이 300초 안에 끝나지 않았다");
        // 여기서 실패하면 재실행은 이 단계를 same으로 건너뛴다. 같은 확인을 --finish가 PREVIOUS를 지우기 전에 다시 한다.
        await verifyLive(w, n);
      },
    },
  ];
}

function finishSteps(n: Names, app: string): Step[] {
  return [
    registered(n),
    {
      id: "consistent",
      target: "회전 결과",
      async read(ctx) {
        const p = phase(ctx, n);
        if (p.prev === null) return same("회전 기록 없음(PASSWORD_PREVIOUS 없음)");
        const next = `homelab db rotate ${app} --apply`;
        if (p.pending) return { state: "differs", action: "none", detail: "새 값이 아직 없다", next };
        if (ctx.k8s.secretHash("database", n.roleSecret, "password") !== p.cur) return { state: "differs", action: "none", detail: "역할 Secret이 새 값이 아니다", next };
        if (!roleState(ctx, n).ok) return { state: "differs", action: "none", detail: "CNPG가 새 값을 적용하지 않았다", next };
        if (dbUrlState(ctx, n) !== true) return { state: "differs", action: "none", detail: "앱 연결 Secret이 새 값이 아니다", next };
        if (!deployCurrent(ctx, n)) return { state: "differs", action: "none", detail: "앱이 새 Secret으로 다시 뜨지 않았다", next };
        return same("새 값이 역할·앱까지 반영됨");
      },
    },
    {
      id: "previous-removed",
      target: `Infisical ${n.folder}/${PREVIOUS}`,
      async read(ctx) {
        return ctx.infisical.valueHash(n.folder, PREVIOUS) === null ? same("없음") : { state: "differs", action: "delete", detail: "있음 → 헬스·새 값 접속·옛 값 거부를 다시 본 뒤 지움" };
      },
      async apply(w) {
        await verifyLive(w, n);
        w.infisical.removeKey(n.folder, PREVIOUS);
      },
    },
  ];
}

export default defineCommand({
  path: ["db", "rotate"],
  summary: "DB 비밀번호 회전(C.6.5). --finish로 옛 값 정리",
  kind: "change",
  args: [{ name: "app", required: true, help: "앱 이름", pattern: APP_NAME }],
  flags: [{ name: "finish", kind: "bool", help: "회전을 끝낸다: 다시 확인한 뒤 PASSWORD_PREVIOUS를 지운다" }],
  async run(ctx, input) {
    const app = input.args.app as string;
    const n = namesOf(app);
    const finish = input.flags.finish === true;
    return ctx.engine({
      command: "db rotate",
      app,
      steps: finish ? finishSteps(n, app) : startSteps(n),
      notes: finish
        ? ["옛 값은 지우면 되돌릴 수 없다(Infisical Free에는 버전 이력이 없다). 지우기 직전에 다시 확인한다."]
        : ["역할 Secret 동기화부터 앱 재시작까지 옛 값으로 새 연결을 여는 파드는 실패한다(T11 약 17~20초). 이미 열린 연결은 유지된다."],
      next: finish ? undefined : (status) => (status === "done" || status === "same" ? `homelab db rotate ${app} --finish` : KEEP),
    });
  },
});
