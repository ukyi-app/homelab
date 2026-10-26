// homelab data purge <app> --confirm <app>: 앱을 지운 뒤 남은 데이터 폐기(설계 C.5.5, AC-7).
//
// 순서: 사전 확인(앱 삭제됨, 앱 삭제 뒤 백업 있음) → PR 1(data values에 purge: true, 데이터 차트 1.0.2) → 동기화 확인 →
// Valkey PV reclaim Delete → PR 2(data/<app> 삭제) → CR·PVC·PV가 사라졌는지 → Infisical 키(tty에서 앱 이름을 한 번 더 친 뒤).
// 함정: 보호 주석(Prune=false,Delete=false)이 살아 있는 리소스에서 빠지기 전에 PR 2가 병합되면 Argo CD가 리소스를 남긴 채
// Application만 지운다. 그래서 PR 2는 동기화를 확인한 다음 실행에서만 연다(같은 PR에 넣지 않는다, 데이터 차트 _helpers.tpl).
// 상태 저장소 없이 이어지도록 단계마다 main 파일과 살아 있는 리소스를 읽어 어디까지 왔는지 판단한다.
import { defineCommand, type Observation, type ReadCtx, type Step, type WriteCtx } from "../core/command";
import { APP_NAME } from "../core/names";
import { prStep } from "../core/pr";
import { UsageError } from "../core/result";
import { parseYaml, setTopLevel } from "../core/values";

const REPO = "repos/ukyi-app/homelab";
const PURGE_CHART = "1.0.2";
const PROTECT = "argocd.argoproj.io/sync-options";

const same = (detail: string, extra: Partial<Observation> = {}): Observation => ({ state: "same", action: "none", detail, ...extra });

type Names = { app: string; ns: string; dataFile: string };

function values(ctx: ReadCtx | WriteCtx, path: string): any | null {
  const text = ctx.repo.readFile(path);
  return text === null ? null : parseYaml(text);
}

function semverAtLeast(v: unknown, min: string): boolean {
  if (typeof v !== "string" || !/^[0-9]+\.[0-9]+\.[0-9]+$/.test(v)) return false;
  const a = v.split(".").map(Number);
  const b = min.split(".").map(Number);
  for (let i = 0; i < 3; i++) if (a[i] !== b[i]) return a[i] > b[i];
  return true;
}

// 저장소 폴더의 파일 목록(contents API). 없으면 [].
function listDir(ctx: ReadCtx, dir: string): string[] {
  const r = ctx.gh.get(`${REPO}/contents/${dir}?ref=main`);
  if (r.status === 404) return [];
  if (r.status !== 200 || !Array.isArray(r.json)) throw new Error(`${dir} 목록을 읽지 못했다(HTTP ${r.status})`);
  return r.json.map((e: { type?: string; path?: string }) => {
    if (e.type !== "file" || typeof e.path !== "string") throw new Error(`${dir} 안에 파일이 아닌 것이 있다. 손으로 확인한다`);
    return e.path;
  });
}

type Baseline = { date: string; removed: number; what: string } | { problem: string };

function commitDates(ctx: ReadCtx, path: string, perPage: number): string[] | { problem: string } {
  const r = ctx.gh.get(`${REPO}/commits?path=${encodeURIComponent(path)}&sha=main&per_page=${perPage}`);
  if (r.status !== 200 || !Array.isArray(r.json)) return { problem: `${path} 이력을 읽지 못했다(HTTP ${r.status})` };
  const dates = r.json.map((c: any) => c?.commit?.committer?.date);
  if (dates.some((d: unknown) => typeof d !== "string" || !Number.isFinite(Date.parse(d as string)))) return { problem: `${path} 이력의 커밋 시각 형식이 아니다` };
  return dates as string[];
}

const MAX_WALK = 30;

// 지금 data/<app>/values.yaml이 생긴 커밋(가장 최근의 added)의 시각. 폐기 뒤 재등록이면 그 재등록이다(#883 r2 P1-2).
// 새것부터 커밋마다 그 파일의 상태(added·modified·removed)를 읽는다. PR 1(purge: true)은 modified라 지나간다.
// 생긴 커밋을 MAX_WALK 안에서 못 찾거나 모양이 다르면 정할 수 없다(멈춘다).
function dataRegistered(ctx: ReadCtx, path: string): { date: string } | { problem: string } {
  const r = ctx.gh.get(`${REPO}/commits?path=${encodeURIComponent(path)}&sha=main&per_page=${MAX_WALK}`);
  if (r.status !== 200 || !Array.isArray(r.json)) return { problem: `${path} 이력을 읽지 못했다(HTTP ${r.status})` };
  for (const c of r.json) {
    const sha = c?.sha;
    const date = c?.commit?.committer?.date;
    if (typeof sha !== "string" || !/^[0-9a-f]{40}$/.test(sha) || typeof date !== "string" || !Number.isFinite(Date.parse(date))) return { problem: `${path} 이력의 커밋 모양이 다르다` };
    const d = ctx.gh.get(`${REPO}/commits/${sha}`);
    const files = d.status === 200 && Array.isArray(d.json?.files) ? d.json.files : null;
    if (!files) return { problem: `커밋 ${sha.slice(0, 7)}의 파일 목록을 읽지 못했다(HTTP ${d.status})` };
    // 커밋이 파일 300개를 넘으면 목록이 잘린다. 그 파일이 없으면 판단할 수 없다.
    const f = files.find((x: any) => x?.filename === path);
    if (!f) return { problem: `커밋 ${sha.slice(0, 7)}에서 ${path}의 변경을 찾지 못했다` };
    if (f.status === "added" || f.status === "renamed" || f.status === "copied") return { date };
    if (f.status !== "modified" && f.status !== "changed") return { problem: `${path}이 지금 있는데 이력의 상태가 ${String(f.status)}다` };
  }
  return { problem: `${path}이 생긴 커밋을 최근 ${MAX_WALK}개 안에서 찾지 못했다` };
}

// 백업 기준 시각: 앱 삭제(apps/<app>의 마지막 커밋)와 지금 데이터 등록 중 늦은 쪽. 앱을 지운 뒤 데이터를 다시 등록했으면
// 앱 삭제 뒤 백업이라도 새 데이터를 담지 않았을 수 있다. 앱 이력이 없으면(앱 없이 등록한 데이터) 데이터 등록만.
function baseline(ctx: ReadCtx, app: string): Baseline {
  const apps = commitDates(ctx, `apps/${app}/values.yaml`, 1);
  if (!Array.isArray(apps)) return apps;
  const reg = dataRegistered(ctx, `data/${app}/values.yaml`);
  if ("problem" in reg) return reg;
  const removed = apps.length > 0 ? Date.parse(apps[0]) : Number.NEGATIVE_INFINITY;
  const registered = Date.parse(reg.date);
  if (removed >= registered) return { date: apps[0], removed, what: "앱 삭제" };
  return { date: reg.date, removed: registered, what: apps.length > 0 ? "데이터 재등록(앱 삭제 뒤)" : "데이터 등록(앱 이력 없음)" };
}

const protectedOf = (o: any) => /Delete=false|Prune=false/.test(String(o?.metadata?.annotations?.[PROTECT] ?? ""));

// PR 1이 살아 있는 리소스에 반영됐는지. 남은 것을 이름으로 돌려준다.
function notPrepared(ctx: ReadCtx, n: Names, data: any): string[] {
  const left: string[] = [];
  if (data?.postgres?.enabled === true) {
    // 없는 CR을 "반영됨"으로 보지 않는다. CR 없이 PR 2를 내면 DB·역할이 PostgreSQL에 남아도 이 명령은 알 수 없다.
    const db = ctx.k8s.get("database", "database", n.app);
    if (!db || protectedOf(db) || db.spec?.databaseReclaimPolicy !== "delete") left.push(`Database ${n.app}${db ? "" : "(없음)"}`);
    const role = ctx.k8s.get("databaserole", "database", n.app);
    if (!role || protectedOf(role) || role.spec?.databaseRoleReclaimPolicy !== "delete") left.push(`DatabaseRole ${n.app}${role ? "" : "(없음)"}`);
  }
  if (data?.valkey?.persistent === true) {
    const pvc = ctx.k8s.get("pvc", n.ns, "valkey-data");
    if (!pvc || protectedOf(pvc)) left.push(`PVC valkey-data${pvc ? "" : "(없음)"}`);
  }
  return left;
}

// PR 2 뒤 아직 남은 것.
function remaining(ctx: ReadCtx, n: Names): string[] {
  const left: string[] = [];
  if (ctx.k8s.get("application", "argocd", `${n.app}-data`)) left.push(`Application ${n.app}-data`);
  if (ctx.k8s.get("database", "database", n.app)) left.push(`Database ${n.app}`);
  if (ctx.k8s.get("databaserole", "database", n.app)) left.push(`DatabaseRole ${n.app}`);
  if (ctx.k8s.get("pvc", n.ns, "valkey-data")) left.push("PVC valkey-data");
  for (const pv of ctx.k8s.list("pv", null)) if (pv?.spec?.claimRef?.namespace === n.ns && pv?.spec?.claimRef?.name === "valkey-data") left.push(`PV ${pv.metadata?.name}`);
  return left;
}

function secretKeys(ctx: ReadCtx | WriteCtx, app: string): { path: string; key: string }[] {
  const out: { path: string; key: string }[] = [];
  for (const path of [`/apps/${app}/postgres`, `/apps/${app}/valkey`, `/apps/${app}`]) {
    if (!ctx.infisical.folderExists(path)) continue;
    for (const key of ctx.infisical.listKeys(path)) out.push({ path, key });
  }
  return out;
}

// PR을 연 뒤에는 병합될 때까지 뒤 단계를 돌리지 않는다(prStep의 wait → hold).
function holdUntilMerged(id: string, step: Step): Step {
  return {
    ...step,
    id,
    async read(ctx) {
      const o = await step.read(ctx);
      return o.state === "same" && o.wait ? { ...o, hold: o.wait, wait: undefined } : o;
    },
  };
}

// 앞 PR이 병합되기 전에는 이 단계에 올 수 없다(apply 순서상 앞 단계가 멈춘다). plan에서만 보이는 "예정" 관찰.
function afterPr(detail: string): Observation {
  return { state: "missing", action: "none", detail };
}

function steps(n: Names, dataFiles: string[]): Step[] {
  const app = n.app;
  return [
    {
      id: "app-removed",
      target: `앱 ${app}`,
      async read(ctx) {
        if (listDir(ctx, `apps/${app}`).length > 0) return { state: "differs", action: "none", detail: `apps/${app}/가 아직 있다`, next: `homelab app remove ${app}` };
        if (ctx.k8s.get("application", "argocd", app)) return { state: "differs", action: "none", detail: `Application ${app}이 아직 있다(삭제 동기화 대기)`, next: `homelab status ${app}` };
        return same("앱 삭제됨");
      },
    },
    {
      id: "backup",
      target: "앱 삭제 뒤 백업",
      async read(ctx) {
        const data = values(ctx, n.dataFile);
        if (data === null) return same(`data/${app} 없음(PR 2 뒤라 확인하지 않는다)`);
        // 기준 시각을 못 정하면 통과시키지 않는다(#883 r1 P1-2). 앱이 있었으면 apps/<app>/values.yaml의 마지막 커밋(삭제),
        // 앱 없이 데이터만 등록했으면(시나리오 10의 probe2) data/<app>/values.yaml의 첫 커밋(등록). 첫 커밋은 PR 1이 같은
        // 파일을 고쳐도 움직이지 않는다.
        const base = baseline(ctx, app);
        if ("problem" in base) return { state: "differs", action: "none", detail: base.problem, next: "GitHub 이력을 확인한 뒤 다시 실행한다(기준 시각 없이는 백업을 판단하지 않는다)" };
        const { date, removed, what } = base;
        const after = (t: unknown) => typeof t === "string" && Date.parse(t) > removed;
        const lacks: string[] = [];
        if (data.postgres?.enabled === true) {
          const ok = ctx.k8s.list("backup", "database").some((b) => b?.spec?.cluster?.name === "pg" && b?.status?.phase === "completed" && after(b?.status?.stoppedAt));
          if (!ok) lacks.push("completed base backup");
        }
        if (data.valkey?.persistent === true) {
          const cj = ctx.k8s.get("cronjob", n.ns, `${app}-valkey-backup`);
          if (!after(cj?.status?.lastSuccessfulTime)) lacks.push("Valkey 백업");
        }
        if (lacks.length) return { state: "differs", action: "none", detail: `${what}(${date}) 뒤 ${lacks.join("·")}이 없다`, next: "다음 정기 백업(PostgreSQL 03:00, Valkey 03:30 KST) 뒤 다시 실행한다" };
        return same(`${what}(${date}) 뒤 백업 있음`);
      },
    },
    {
      id: "inventory",
      target: "지울 데이터",
      async read(ctx) {
        const data = values(ctx, n.dataFile);
        if (data === null) return same(`data/${app} 없음`);
        const items: string[] = [];
        if (data.postgres?.enabled === true) items.push(`Database·DatabaseRole ${app}(DROP)`);
        if (data.valkey?.persistent === true) items.push(`영속 Valkey PVC valkey-data와 PV, CronJob ${app}-valkey-backup`);
        return same(items.length ? items.join(", ") : "데이터 리소스 없음");
      },
    },
    {
      id: "chart",
      target: `데이터 차트 ${PURGE_CHART}`,
      async read(ctx) {
        const data = values(ctx, n.dataFile);
        if (data === null || (data.purge === true && semverAtLeast(data.chartVersion, PURGE_CHART))) return same("확인할 것 없음");
        const r = ctx.gh.get(`${REPO}/git/ref/tags/data-chart-v${PURGE_CHART}`);
        if (r.status === 200) return same(`태그 data-chart-v${PURGE_CHART} 있음`);
        return { state: "missing", action: "none", detail: `태그 data-chart-v${PURGE_CHART}가 없다(purge 값은 ${PURGE_CHART}부터)`, next: "데이터 차트 1.0.2 태그가 생긴 뒤 다시 실행한다" };
      },
    },
    holdUntilMerged(
      "pr-prepare",
      prStep({
        command: "data purge",
        app,
        title: `purge: prepare ${app}`,
        body: [
          `\`homelab data purge ${app}\`의 PR 1(설계 C.5.5).`,
          "",
          `- \`data/${app}/values.yaml\`에 \`purge: true\`(데이터 차트 ${PURGE_CHART}부터): 보호 주석을 빼고 Database·DatabaseRole reclaim을 delete로.`,
          "- 병합·동기화를 확인한 뒤 같은 명령이 PR 2(`data/" + app + "/` 삭제)를 연다. PR 2가 병합되면 DB·역할·Valkey PVC와 PV가 지워진다.",
        ].join("\n"),
        files: [n.dataFile],
        edit(cur) {
          const text = cur[n.dataFile];
          if (text === null) return { [n.dataFile]: null };
          const v: any = parseYaml(text);
          if (v?.purge === true && semverAtLeast(v.chartVersion, PURGE_CHART)) return { [n.dataFile]: text };
          return { [n.dataFile]: setTopLevel(text, { chartVersion: semverAtLeast(v?.chartVersion, PURGE_CHART) ? v.chartVersion : PURGE_CHART, purge: true }) };
        },
      }),
    ),
    {
      id: "prepared",
      target: "보호 주석·reclaim 반영",
      async read(ctx) {
        const data = values(ctx, n.dataFile);
        if (data === null) return same("PR 2 뒤");
        if (data.purge !== true) return afterPr("PR 1 병합 뒤 확인");
        const left = notPrepared(ctx, n, data);
        return left.length ? same("main에 purge: true", { hold: `Argo CD 동기화 대기(${left.join(", ")})` }) : same("보호 주석 없음, reclaim delete");
      },
      async apply() {
        throw new Error("PR 1이 아직 병합되지 않았다");
      },
    },
    {
      id: "pv-reclaim",
      target: `PV(${n.ns}/valkey-data)`,
      async read(ctx) {
        const data = values(ctx, n.dataFile);
        if (data === null || data.valkey?.persistent !== true) return same("영속 Valkey 없음");
        const pvc = ctx.k8s.get("pvc", n.ns, "valkey-data");
        // PVC가 없으면 앞 단계(prepared)가 멈춘다. 여기까지 왔는데 없으면 PR 2 뒤이거나 바깥에서 지운 것이라 바꿀 PV가 없다.
        if (!pvc) return same("PVC 없음");
        const pv = typeof pvc.spec?.volumeName === "string" ? ctx.k8s.get("pv", null, pvc.spec.volumeName) : null;
        // 묶인 PV를 못 찾으면 reclaim을 확인할 수 없다. 폴더가 남는 쪽으로 넘어가지 않고 멈춘다.
        if (!pv) return { state: "differs", action: "none", detail: "PVC에 묶인 PV를 찾지 못했다(reclaim을 확인할 수 없다)", next: `kubectl -n ${n.ns} get pvc valkey-data -o wide로 본다` };
        if (pv.spec?.persistentVolumeReclaimPolicy === "Delete") return same("reclaim Delete");
        if (data.purge !== true) return afterPr("PR 1 뒤 reclaim Retain → Delete");
        return { state: "differs", action: "update", detail: "reclaim Retain → Delete(PVC가 지워질 때 노드 폴더도 지워지게)" };
      },
      async apply(w) {
        w.k8s.setPvReclaimDelete(n.ns, "valkey-data");
      },
    },
    holdUntilMerged(
      "pr-delete",
      prStep({
        command: "data purge delete",
        app,
        title: `purge: delete data/${app}`,
        body: [`\`homelab data purge ${app}\`의 PR 2(설계 C.5.5).`, "", `- \`data/${app}/\`를 지운다. Application \`${app}-data\`가 지워지며 Database·DatabaseRole(DROP)과 Valkey PVC·PV가 사라진다.`, "- 폐기 뒤에도 그 DB는 base backup 안에 보존 기간(14일) 동안 남는다."].join("\n"),
        files: dataFiles,
        edit: (cur) => Object.fromEntries(Object.keys(cur).map((k) => [k, null])),
      }),
    ),
    {
      id: "gone",
      target: "남은 데이터 리소스",
      async read(ctx) {
        if (values(ctx, n.dataFile) !== null) return afterPr("PR 2 병합 뒤 확인");
        const left = remaining(ctx, n);
        return left.length ? same("main에서 지움", { hold: `Argo CD·CNPG가 지우는 중(${left.join(", ")})` }) : same("모두 사라짐");
      },
      async apply() {
        throw new Error("PR 2가 아직 병합되지 않았다");
      },
    },
    {
      id: "secrets",
      target: `Infisical /apps/${app}`,
      async read(ctx) {
        const keys = secretKeys(ctx, app);
        if (keys.length === 0) return same("키 없음");
        const list = keys.map((k) => `${k.path}/${k.key}`).join(", ");
        if (values(ctx, n.dataFile) !== null) return afterPr(`PR 2 뒤 키 ${keys.length}개(${list}) 삭제(앱 이름을 다시 친 뒤)`);
        return { state: "differs", action: "delete", detail: `키 ${keys.length}개(${list}) → 앱 이름을 다시 친 뒤 지움` };
      },
      async apply(w) {
        const keys = secretKeys(w, app);
        if (!w.confirm(`Infisical /apps/${app} 아래 키 ${keys.length}개를 지운다. 되돌릴 수 없다. 앱 이름을 다시 친다: `, app)) {
          throw new Error("확인하지 않았다(터미널에서 앱 이름을 다시 쳐야 지운다)");
        }
        for (const k of keys) w.infisical.removeKey(k.path, k.key);
      },
    },
  ];
}

export default defineCommand({
  path: ["data", "purge"],
  summary: "데이터 폐기(C.5.5). --apply와 --confirm <app> 둘 다 있어야 실행",
  kind: "change",
  args: [{ name: "app", required: true, help: "앱 이름", pattern: APP_NAME }],
  flags: [{ name: "confirm", kind: "value", valueName: "app", pattern: APP_NAME, help: "지울 앱 이름을 한 번 더" }],
  async run(ctx, input) {
    const app = input.args.app as string;
    const confirm = input.flags.confirm;
    if (confirm !== undefined && confirm !== app) throw new UsageError("--confirm 값이 앱 이름과 다르다");
    if (input.apply && confirm === undefined) throw new UsageError(`--apply에는 --confirm ${app}이 함께 있어야 한다`);
    const n: Names = { app, ns: `app-${app}`, dataFile: `data/${app}/values.yaml` };
    const listed = listDir(ctx, `data/${app}`);
    const dataFiles = listed.length ? listed : [n.dataFile];
    return ctx.engine({
      command: "data purge",
      app,
      steps: steps(n, dataFiles),
      notes: ["폐기 뒤에도 그 DB는 base backup 안에 보존 기간(14일) 동안 남는다.", `앱 ns app-${app}과 Infisical 폴더는 남는다(키만 지운다).`],
      next: (status) => (status === "pending" ? `homelab data purge ${app} --confirm ${app} --apply` : (undefined as unknown as string | null)),
    });
  },
});
