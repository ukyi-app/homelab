// homelab data purge <app> --confirm <app>: 앱을 지운 뒤 남은 데이터 폐기(설계 C.5.5, AC-7).
//
// 순서: 사전 확인(앱 삭제됨, 앱 삭제 뒤 백업 있음) → PR 1(data values에 purge: true, 데이터 차트 1.0.2) → 동기화 확인 →
// Valkey PV reclaim Delete → PR 2(data/<app> 삭제) → CR·PVC·PV가 사라졌는지 → Infisical 키(tty에서 앱 이름을 한 번 더 친 뒤).
// 함정: 보호 주석(Prune=false,Delete=false)이 살아 있는 리소스에서 빠지기 전에 PR 2가 병합되면 Argo CD가 리소스를 남긴 채
// Application만 지운다. 그래서 PR 2는 동기화를 확인한 다음 실행에서만 연다(같은 PR에 넣지 않는다, 데이터 차트 _helpers.tpl).
// 상태 저장소 없이 이어지도록 단계마다 main 파일과 살아 있는 리소스를 읽어 어디까지 왔는지 판단한다.
import { defineCommand, type Observation, type ReadCtx, type Step, type WriteCtx } from "../core/command";
import { APP_NAME, newRunId } from "../core/names";
import { prStep } from "../core/pr";
import { UsageError, type Result } from "../core/result";
import { parseYaml, setTopLevel } from "../core/values";

const REPO = "repos/ukyi-app/homelab";
const PURGE_CHART = "1.0.2";
const PROTECT = "argocd.argoproj.io/sync-options";
// R2 valkey/ 객체는 올린 뒤 14일(1,209,600초)에 지워진다(infra/cloudflare/main.tf valkey-expire-14d).
// 여유 2일: 객체는 Job 성공 시각보다 먼저 올라가고, PR 2는 이 확인 뒤 사람이 병합한다(#883 r3 P1-1).
const VALKEY_KEEP_MS = 14 * 86_400_000;
const VALKEY_MARGIN_MS = 2 * 86_400_000;
// 이 기기와 클러스터의 시계 차이로 보는 범위. 이보다 미래의 성공 시각은 믿지 않는다.
const CLOCK_SKEW_MS = 3_600_000;
// CNPG ObjectStore r2의 retentionPolicy 14d(platform/cnpg/cluster/templates/objectstore.yaml). CR이 남아도 객체는 지워졌을 수 있다.
// Valkey와 같은 2일 여유를 둔다(#889 r1 P1-4).
const PG_KEEP_MS = 14 * 86_400_000;
// 앱이 쓰기를 멈춘 시각은 Git 삭제 커밋이 아니라 이 명령이 클러스터에서 앱 워크로드가 없음을 본 시각이다. Argo CD가 늦거나
// 멈추면 커밋 뒤 몇 시간이라도 앱이 쓴다(#889 r1 P1-2). 없음을 본 직후 기록 data-purge를 만들고, 그 creationTimestamp(API
// 서버 시계)보다 뒤에 시작한 백업만 인정한다. 백업 시각도 클러스터 시계라 이 기기와의 시계 차이가 끼지 않는다(#889 r2 P2-5).
// 기록은 앱마다 database ns의 data-purge-<app>다. 앱 ns가 없는 PostgreSQL 전용 데이터도 같은 자리에 둔다. 앱이 없어도 사람이
// DB에 쓸 수 있고(시나리오 10의 probe2) DB가 등록 커밋보다 늦게 생길 수 있어, 등록 시각만으로는 판단하지 않는다(#889 r3 P1-2).
// database ns는 CNPG가 있어 늘 있고 restore-check 기록도 그 ns에 있다.
const REC_NS = "database";
const recordName = (app: string) => `data-purge-${app}` as const;

const hasTrue = (o: any, type: string) => (o?.status?.conditions ?? []).some((c: any) => c?.type === type && c?.status === "True");

// 그 앱의 백업 CronJob이 만든(정기·수동 모두 ownerReferences가 CronJob) 성공한 Job 중 가장 늦게 시작한 것의 시작 시각.
// 완료 시각(lastSuccessfulTime)이 아니라 시작 시각을 본다. 스냅샷(initContainer의 valkey-cli --rdb)은 Job 시작 뒤, 업로드 전에
// 찍히므로 완료가 기준보다 늦어도 스냅샷은 기준 전일 수 있다. 시작이 기준 뒤면 스냅샷도 기준 뒤다.
function lastBackupStart(ctx: ReadCtx, ns: string, cronjob: string): string | null {
  let best: string | null = null;
  for (const j of ctx.k8s.list("job", ns)) {
    const owned = (j?.metadata?.ownerReferences ?? []).some((o: any) => o?.kind === "CronJob" && o?.name === cronjob);
    const t = j?.status?.startTime;
    if (!owned || !hasTrue(j, "Complete") || typeof t !== "string" || !Number.isFinite(Date.parse(t))) continue;
    if (best === null || Date.parse(t) > Date.parse(best)) best = t;
  }
  return best;
}

const same = (detail: string, extra: Partial<Observation> = {}): Observation => ({ state: "same", action: "none", detail, ...extra });
const SEEN = "앱 워크로드가 보인다";

const live = (p: any) => p?.status?.phase !== "Succeeded" && p?.status?.phase !== "Failed";

// 데이터 차트가 띄우는 파드: Valkey 서버(서브차트 라벨), 백업 CronJob·수동 백업·복원 Job의 파드. 앱이 쓰지 않는다.
function dataPod(p: any, app: string): boolean {
  const l = p?.metadata?.labels ?? {};
  if (l["app.kubernetes.io/name"] === "valkey" && l["app.kubernetes.io/instance"] === app) return true;
  const job = l["batch.kubernetes.io/job-name"] ?? l["job-name"];
  return typeof job === "string" && (job.startsWith(`${app}-valkey-backup-`) || /^backup-[a-z0-9]{1,22}-[0-9a-f]{4}$/.test(job) || job === "restore-vk");
}

// 앱 ns에 남은 앱 워크로드. 앱 차트 라벨이 붙은 것과, 데이터 차트 것으로 알아볼 수 없는 살아 있는 파드(누가 쓰는지 모른다).
function appWorkloads(ctx: ReadCtx | WriteCtx, n: Names): string[] {
  const own = (o: any) => o?.metadata?.labels?.["homelab.ukyi.app/app"] === n.app || o?.metadata?.labels?.["app.kubernetes.io/name"] === n.app;
  const out: string[] = [];
  // 모든 워크로드 읽기가 여기를 지난다(전용 엔진, 사전 읽기, 재조회, 쓰기 뒤 재조회, guarded 안 확인). 본 것은 잊지 않는다(#893 r2).
  // 찾는 즉시 남긴다. 다음 종류 조회가 예외로 끝나도 앞에서 본 것이 사라지지 않게(#893 r3).
  const found = (x: string) => {
    n.seen.add(x);
    out.push(x);
  };
  // 앱 ns가 없으면 목록은 비어 있다(앱이 처음부터 없거나 지워졌다). 앱 Application이 남아 있으면 곧 다시 띄울 수 있다.
  if (ctx.k8s.get("application", "argocd", n.app)) found(`application/${n.app}`);
  for (const kind of ["deployment", "statefulset", "cronjob", "job"] as const) {
    for (const o of ctx.k8s.list(kind, n.ns)) if (own(o) || (kind === "deployment" && o?.metadata?.name === n.app)) found(`${kind}/${o?.metadata?.name}`);
  }
  for (const p of ctx.k8s.list("pod", n.ns)) if (live(p) && (own(p) || !dataPod(p, n.app))) found(`pod/${p?.metadata?.name}`);
  return out;
}

// 지금 보이는 워크로드, 없으면 이 실행에서 앞서 본 것. 한 번 보면 그 뒤 읽기는 사라졌어도 본 것으로 판정한다(#893 r2 A).
function observed(ctx: ReadCtx | WriteCtx, n: Names): string[] {
  const left = appWorkloads(ctx, n);
  return left.length ? left : [...n.seen];
}

// 기록된 "앱 워크로드 없음" 확인 시각(기록의 creationTimestamp). 지금 기준(앱 삭제·데이터 등록)보다 앞이면 옛 실행의 것이라
// 쓰지 않는다. 확인 뒤 워크로드가 다시 보이면 writes-stopped가 기록을 지운다(#889 r2 P1-3).
function goneAt(ctx: ReadCtx | WriteCtx, n: Names, removed: number): string | null {
  const t = ctx.k8s.restoreRecord(REC_NS, recordName(n.app))?.created;
  return typeof t === "string" && Number.isFinite(Date.parse(t)) && Date.parse(t) > removed ? t : null;
}


// 백업 시각 t가 보존 기간 안인지. 문제면 그 설명.
function staleness(t: string, keepMs: number): string | null {
  const age = Date.now() - Date.parse(t);
  if (age < -CLOCK_SKEW_MS) return "지금보다 미래다(시계를 믿을 수 없다)";
  if (age > keepMs - VALKEY_MARGIN_MS) return `${Math.round((keepMs - VALKEY_MARGIN_MS) / 86_400_000)}일보다 오래됐다(보존 ${Math.round(keepMs / 86_400_000)}일 뒤 지워진다)`;
  return null;
}

// seen: 이 실행에서 한 번이라도 본 앱 워크로드(메모리, 쓰기 아님). 어느 읽기에서 봤든 apply가 끝날 때 기록을 무효화한다.
type Names = { app: string; ns: string; dataFile: string; seen: Set<string> };

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

// 워크로드를 보면 종료 기록은 거짓이 됐다. 지우고 멈춘다. 사라진 뒤 다시 실행하면 그때부터 새로 잰다.
function invalidate(w: WriteCtx, n: Names, left: string[]): never {
  const r = w.k8s.restoreRecord(REC_NS, recordName(n.app));
  if (r) w.k8s.restoreRecordDelete(REC_NS, recordName(n.app), r.run);
  throw new Error(`앱 워크로드가 있다(${left.join(", ")})${r ? ". 폐기 확인 기록을 지웠다" : ""}. kubectl -n ${n.ns} get deploy,sts,cronjob,job,pod --show-labels로 보고, 사라진 뒤 다시 실행한다`);
}

function seen(ctx: ReadCtx, n: Names, left: string[]): Observation {
  const r = ctx.k8s.restoreRecord(REC_NS, recordName(n.app));
  return { state: "differs", action: r ? "delete" : "none", detail: `${SEEN}(${left.join(", ")})${r ? " → 폐기 확인 기록이 무효가 된다. 지우고" : ""} 멈춘다` };
}

// 클러스터에서 앱 워크로드와 기록만 본다(GitHub·Infisical·백업 조회 없음). apply 때 본 엔진보다 먼저 따로 돈다(#893 r1 P1-2).
// 본 엔진의 사전 읽기는 다른 서비스 하나만 실패해도 apply 전에 돌아가 무효화가 돌지 않는다.
function workloadStep(n: Names): Step {
  return {
    id: "workloads",
    target: `앱 워크로드(${n.ns})`,
    async read(ctx) {
      const left = observed(ctx, n);
      return left.length ? seen(ctx, n, left) : same("없음");
    },
    async apply(w) {
      // 읽을 때 봤으면 지금 사라졌어도 무효화한다(그사이 썼을 수 있다).
      const left = appWorkloads(w, n);
      invalidate(w, n, left.length ? left : ["읽을 때 본 워크로드"]);
    },
  };
}

// PR 2 전 단계(백업 확인·PR·PV)는 읽을 때마다 워크로드를 먼저 본다. 보이면 same으로 넘기지 않고 기록 삭제로 판정하고, apply에서
// 지운 뒤 실패한다(#893 r1 P1-1). 확인만 하는 단계의 실패는 read에서 던진다. 그 단계에 apply가 생겨도 엔진이 apply 전에 막게.
// 쓰는 단계는 쓰기 직전에 한 번 더 본다.
function guarded(n: Names, step: Step): Step {
  const check = !step.apply;
  return {
    ...step,
    async read(ctx) {
      if (values(ctx, n.dataFile) === null) return step.read(ctx);
      const left = observed(ctx, n);
      if (left.length) return seen(ctx, n, left);
      const o = await step.read(ctx);
      if (check && o.state !== "same") throw new Error(o.next ? `${o.detail}. ${o.next}` : o.detail);
      return o;
    },
    async apply(w, o) {
      // 읽을 때 봤으면 지금 사라졌어도 무효화한다. 쓰는 단계는 쓰기 직전에 다시 본다.
      const left = appWorkloads(w, n);
      if (o.detail.startsWith(SEEN) || left.length) invalidate(w, n, left.length ? left : ["읽을 때 본 워크로드"]);
      if (!step.apply) throw new Error(o.detail);
      await step.apply(w, o);
      // 쓴 직후에도 본다. 엔진의 쓰기 뒤 재조회가 워크로드를 보면 그냥 실패할 뿐 기록을 지우지 못한다.
      const after = appWorkloads(w, n);
      if (after.length) invalidate(w, n, after);
    },
  };
}

// 이 실행에서 워크로드를 봤을 때 마지막에 도는 단계. 지금 없어도 지운다. 기록이 없으면 할 일 없음.
function dropRecord(n: Names, list: string): Step {
  return {
    id: "record-invalidated",
    target: `기록 ${REC_NS}/${recordName(n.app)}`,
    async read(ctx) {
      const r = ctx.k8s.restoreRecord(REC_NS, recordName(n.app));
      return r ? { state: "differs", action: "delete", detail: `이 실행에서 앱 워크로드를 봤다(${list}) → 폐기 확인 기록이 무효가 된다` } : same("기록 없음(무효)");
    },
    async apply(w) {
      const r = w.k8s.restoreRecord(REC_NS, recordName(n.app));
      if (r) w.k8s.restoreRecordDelete(REC_NS, recordName(n.app), r.run);
    },
  };
}

function steps(n: Names, dataFiles: string[]): Step[] {
  const app = n.app;
  const g = (step: Step) => guarded(n, step);
  return [
    workloadStep(n),
    {
      id: "app-removed",
      target: `앱 ${app}`,
      async read(ctx) {
        if (listDir(ctx, `apps/${app}`).length > 0) return { state: "differs", action: "none", detail: `apps/${app}/가 아직 있다`, next: `homelab app remove ${app}` };
        // Application과 앱 워크로드는 writes-stopped가 본다. 여기서 막으면 쓰기 단계에 닿지 못해 옛 종료 기록을 지울 수 없다(#889 r2 P1-3).
        return same("main에서 앱 삭제됨");
      },
    },
    g({
      id: "writes-stopped",
      target: "앱 쓰기가 멈춘 시각",
      async read(ctx) {
        if (values(ctx, n.dataFile) === null) return same("PR 2 뒤");
        const r = ctx.k8s.restoreRecord(REC_NS, recordName(app));
        const base = baseline(ctx, app);
        // 기준을 못 정하면 뒤의 backup 단계가 멈춘다. 여기서는 기록하지 않는다.
        if ("problem" in base) return same("기준 시각 확인은 백업 단계에서");
        const at = goneAt(ctx, n, base.removed);
        if (at) return same(`앱 워크로드 없음 확인 ${at}`);
        return { state: r ? "differs" : "missing", action: "create", detail: `앱 워크로드 없음을 지금 다시 보고 ${REC_NS}/${recordName(app)}을 새로 만든다(그 생성 시각이 기준)` };
      },
      async apply(w) {
        const r = w.k8s.restoreRecord(REC_NS, recordName(app));
        // 워크로드는 guarded가 바로 앞에서 봤다. 기록 시각은 API 서버가 정한다. 옛 기록(기준보다 앞)은 지우고 새로 만든다.
        if (r) w.k8s.restoreRecordDelete(REC_NS, recordName(app), r.run);
        if (w.k8s.restoreRecordCreate(REC_NS, recordName(app), newRunId(), {}) === "exists") throw new Error("그사이 다른 실행이 기록을 만들었다. 다시 실행한다");
      },
    }),
    g({
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
        const gone = goneAt(ctx, n, removed);
        // 앞 단계(writes-stopped)가 apply에서 기록한 뒤 다시 읽힌다. plan과 첫 읽기에서는 아직 없다. apply 중에 여기까지 왔는데
        // 없으면 앞 단계가 기록하지 않은 것이라 통과시키지 않고 멈춘다(hold는 plan에서는 알림으로만 보인다).
        if (!gone) return same("앱 워크로드 없음을 기록한 뒤, 그 뒤에 시작·완료한 백업을 본다", { hold: "폐기 확인 기록이 아직 없다" });
        const since = Math.max(removed, Date.parse(gone));
        const after = (t: unknown) => typeof t === "string" && Number.isFinite(Date.parse(t)) && Date.parse(t) > since;
        const basis = `${what}(${date})·폐기 확인(${gone}) 뒤`;
        const wait = { state: "differs" as const, action: "none" as const, next: "다음 정기 백업(PostgreSQL 03:00, Valkey 03:30 KST)이 성공한 뒤 다시 실행한다" };
        const lacks: string[] = [];
        if (data.postgres?.enabled === true) {
          const done = ctx.k8s.list("backup", "database").filter((b) => b?.spec?.cluster?.name === "pg" && b?.status?.phase === "completed" && after(b?.status?.stoppedAt));
          const t = done.map((b) => b.status.stoppedAt as string).sort((a, b) => Date.parse(b) - Date.parse(a))[0];
          if (!t) lacks.push("completed base backup");
          else {
            const bad = staleness(t, PG_KEEP_MS);
            if (bad) return { ...wait, detail: `${basis}의 마지막 base backup(${t})이 ${bad}` };
          }
        }
        if (data.valkey?.persistent === true) {
          // 성공 Job은 successfulJobsHistoryLimit 1이라 마지막 하나만 남는다. 그 Job이 없으면(지워졌거나 실패만 있음) 판단하지 않는다.
          const t = lastBackupStart(ctx, n.ns, `${app}-valkey-backup`);
          if (!after(t)) lacks.push(`시작한 Valkey 백업(마지막 성공 Job 시작 ${t ?? "없음"})`);
          else {
            // 성공 이력만으로는 객체가 R2에 남아 있다는 증거가 아니다. 백업이 멈춘 채 14일이 지나면 복구할 객체가 없다(#883 r3 P1-1).
            const bad = staleness(t!, VALKEY_KEEP_MS);
            if (bad) return { ...wait, detail: `Valkey 마지막 성공 백업 시작(${t})이 ${bad}`, next: `kubectl -n ${n.ns} get cronjob ${app}-valkey-backup로 suspend·실패를 보고, 새 백업이 성공한 뒤 다시 실행한다` };
          }
        }
        if (lacks.length) return { ...wait, detail: `${basis} ${lacks.join("·")}이 없다` };
        return same(`${basis} 백업 있음`);
      },
    }),
    g({
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
    }),
    g({
      id: "chart",
      target: `데이터 차트 ${PURGE_CHART}`,
      async read(ctx) {
        const data = values(ctx, n.dataFile);
        if (data === null || (data.purge === true && semverAtLeast(data.chartVersion, PURGE_CHART))) return same("확인할 것 없음");
        const r = ctx.gh.get(`${REPO}/git/ref/tags/data-chart-v${PURGE_CHART}`);
        if (r.status === 200) return same(`태그 data-chart-v${PURGE_CHART} 있음`);
        return { state: "missing", action: "none", detail: `태그 data-chart-v${PURGE_CHART}가 없다(purge 값은 ${PURGE_CHART}부터)`, next: "데이터 차트 1.0.2 태그가 생긴 뒤 다시 실행한다" };
      },
    }),
    g(holdUntilMerged(
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
    )),
    g({
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
    }),
    g({
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
    }),
    g(holdUntilMerged(
      "pr-delete",
      prStep({
        command: "data purge delete",
        app,
        title: `purge: delete data/${app}`,
        body: [`\`homelab data purge ${app}\`의 PR 2(설계 C.5.5).`, "", `- \`data/${app}/\`를 지운다. Application \`${app}-data\`가 지워지며 Database·DatabaseRole(DROP)과 Valkey PVC·PV가 사라진다.`, "- 폐기 뒤에도 그 DB는 base backup 안에 보존 기간(14일) 동안 남는다.", "- Valkey 백업은 R2에서 14일 뒤 지워진다. 이 PR을 며칠 뒀으면 병합 전에 같은 명령을 다시 쳐 백업 확인이 통과하는지 본다."].join("\n"),
        files: dataFiles,
        edit: (cur) => Object.fromEntries(Object.keys(cur).map((k) => [k, null])),
      }),
    )),
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
        // PR 2가 병합되고 리소스가 사라지기 전에는 Infisical을 부르지 않는다. 그 조회가 실패하면 사전 읽기 전체가 막혀 앞 단계의
        // 무효화도 돌지 않는다(#893 r1 P1-2). 그때까지는 뒤 단계의 "예정"일 뿐이다.
        if (values(ctx, n.dataFile) !== null) return afterPr("PR 2 뒤 키 삭제(앱 이름을 다시 친 뒤)");
        if (remaining(ctx, n).length) return afterPr("데이터 리소스가 사라진 뒤 키 삭제(앱 이름을 다시 친 뒤)");
        const keys = secretKeys(ctx, app);
        if (keys.length === 0) return same("키 없음");
        const list = keys.map((k) => `${k.path}/${k.key}`).join(", ");
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
    {
      id: "record-removed",
      target: `기록 ${REC_NS}/${recordName(app)}`,
      async read(ctx) {
        const r = ctx.k8s.restoreRecord(REC_NS, recordName(app));
        if (!r) return same("없음");
        if (values(ctx, n.dataFile) !== null) return afterPr("PR 2 뒤 지움");
        return { state: "differs", action: "delete", detail: `실행 ${r.run} 기록 지움` };
      },
      async apply(w) {
        const r = w.k8s.restoreRecord(REC_NS, recordName(app));
        if (r) w.k8s.restoreRecordDelete(REC_NS, recordName(app), r.run);
      },
    },
  ];
}

// 폐기 뒤 남는 것. 앱 ns가 없는 데이터(PostgreSQL 전용, T12-05 probe2)에는 ns를 말하지 않는다(F8). 조사는 앱 이름이 아니라
// "ns"에 붙여 이름의 발음과 상관없이 맞게 한다. ns를 읽지 못하면 있다고 보고 말한다(안내 문구일 뿐이고 단계 읽기가 실패를 보인다).
function leftNote(ctx: ReadCtx, n: Names): string {
  let hasNs = true;
  try {
    hasNs = ctx.k8s.get("namespace", null, n.ns) !== null;
  } catch {
    // 위 주석대로 있다고 본다.
  }
  return hasNs ? `앱 ns(${n.ns})와 Infisical 폴더는 남는다(키만 지운다).` : "Infisical 폴더는 남는다(키만 지운다).";
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
    const n: Names = { app, ns: `app-${app}`, dataFile: `data/${app}/values.yaml`, seen: new Set() };
    const main = async (): Promise<Result> => {
      // apply면 본 엔진 전에 워크로드만 보는 실행을 따로 돌린다. GitHub·Infisical·백업 조회의 실패와 상관없이 무효화가 돈다.
      if (input.apply) {
        const pre = await ctx.engine({ command: "data purge", app, steps: [workloadStep(n)] });
        if (pre.status === "failed") return pre;
      }
      const listed = listDir(ctx, `data/${app}`);
      const dataFiles = listed.length ? listed : [n.dataFile];
      return ctx.engine({
        command: "data purge",
        app,
        steps: steps(n, dataFiles),
        notes: ["폐기 뒤에도 그 DB는 base backup 안에 보존 기간(14일) 동안 남는다.", leftNote(ctx, n)],
        next: (status) => (status === "pending" ? `homelab data purge ${app} --confirm ${app} --apply` : (undefined as unknown as string | null)),
      });
    };
    if (!input.apply) return main();
    // 본 엔진이 어떻게 끝나든(성공·실패·예외·대기) 이 실행에서 워크로드를 봤으면 마지막에 기록을 지우고 실패로 끝낸다(#893 r2).
    // 엔진은 사전 읽기 실패·쓰기 뒤 재조회 실패에서 apply를 부르지 않고 돌아간다. 그 관측을 여기서 받는다.
    let result: Result | undefined;
    let thrown: unknown;
    try {
      result = await main();
    } catch (e) {
      thrown = e;
    }
    if (n.seen.size === 0) {
      if (thrown !== undefined) throw thrown;
      return result!;
    }
    const list = [...n.seen].join(", ");
    const inv = await ctx.engine({ command: "data purge", app, steps: [dropRecord(n, list)] });
    const next =
      inv.status === "failed"
        ? `폐기 확인 기록을 지우지 못했다(${inv.error?.message ?? "원인 미상"}). kubectl -n ${REC_NS} delete configmap ${recordName(app)}로 지운 뒤, 워크로드가 사라지면 다시 실행한다`
        : `kubectl -n ${n.ns} get deploy,sts,cronjob,job,pod --show-labels로 보고, 사라진 뒤 다시 실행한다(그때부터 새로 잰다)`;
    const message = `${result?.error ? `${result.error.message}. ` : ""}이 실행에서 앱 워크로드를 봤다(${list}). ${inv.status === "failed" ? "폐기 확인 기록을 지우지 못했다" : "폐기 확인 기록을 지웠다"}${thrown !== undefined ? `. 본 실행은 예외로 끝났다: ${(thrown as Error)?.message ?? String(thrown)}` : ""}`;
    const base = result ?? inv;
    return { ...base, status: "failed", steps: [...(result?.steps ?? []), ...inv.steps], notes: [...base.notes, ...(result ? inv.notes : [])], next, error: { message, next } };
  },
});
