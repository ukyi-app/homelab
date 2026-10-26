// homelab status: 빌드·배포 PR·Argo CD·파드·시크릿·DB·Valkey·공개 URL의 준비 상태와 다음 행동(설계 C.7, D 9번 상자).
// doctor처럼 확인 단계로 만든다: 준비됨은 same, 문제는 differs/missing + next. 하나라도 문제면 exit 1이고 error.next는
// 첫 문제의 다음 행동이다. 진행 중(동기화·rollout 전)도 문제로 보인다(T12-02 결정, C.7에 적음).
// 읽는 것(T12-02 결정): GitHub(앱 저장소 Actions, homelab의 deploy/<app> PR), Argo CD Application CR, 파드 imageID와
// main image.yaml, ExternalSecret Ready, CNPG DatabaseRole·Database status, 마이그레이션 Job, Valkey Deployment·백업 CronJob,
// 공개 host의 /healthz. 파일은 homelab main에서 읽는다.
import { defineCommand, type Observation, type ReadCtx, type Step } from "../core/command";
import { APP_NAME } from "../core/names";
import { parseYaml } from "../core/values";

type Obj = Record<string, any>;
const ok = (detail: string): Observation => ({ state: "same", action: "none", detail });
const bad = (detail: string, next: string, state: "missing" | "differs" = "differs"): Observation => ({ state, action: "none", detail, next });
const short = (s: unknown, n = 120) => String(s ?? "").replace(/\s+/g, " ").slice(0, n);

function obj(text: string | null): Obj {
  const v = text === null ? null : parseYaml(text);
  return v && typeof v === "object" && !Array.isArray(v) ? (v as Obj) : {};
}

function digestOf(text: string | null): string | null {
  return text === null ? null : (/^digest: (sha256:[0-9a-f]{64})$/m.exec(text)?.[1] ?? null);
}

// GitHub 조회 실패(403·429·5xx)를 "기록 없음"·"PR 없음"으로 읽지 않는다(#884 리뷰 P2-5). 실패는 그 줄의 읽기 실패다.
function ghList(c: ReadCtx, path: string, what: string, field?: string): any[] {
  const r = c.gh.get(path);
  const list = field ? r.json?.[field] : r.json;
  if (r.status !== 200 || !Array.isArray(list)) throw new Error(`${what}: HTTP ${r.status}${r.status === 200 ? "(모양이 다르다)" : ""}`);
  return list;
}

const ready = (o: any) => (o?.status?.conditions ?? []).some((c: any) => c?.type === "Ready" && c?.status === "True");
const wait = (app: string) => `잠시 뒤 다시: homelab status ${app}`;

function argoRow(name: string, app: string): Step {
  return {
    id: `argocd-${name}`,
    target: `Argo CD ${name}`,
    async read(c) {
      const a = c.k8s.get("application", "argocd", name);
      if (!a) return bad("Application 없음", `등록 PR 병합 뒤 1~3분 기다린다. ${wait(app)}`, "missing");
      const sync = a.status?.sync?.status;
      const health = a.status?.health?.status;
      const rev = String(a.status?.sync?.revision ?? "").slice(0, 7);
      if (sync === "Synced" && health === "Healthy") return ok(`Synced·Healthy ${rev}`);
      const op = a.status?.operationState;
      const why = op?.phase && op.phase !== "Succeeded" ? ` (${op.phase}: ${short(op.message)})` : "";
      return bad(`${sync ?? "?"}·${health ?? "?"} ${rev}${why}`, health === "Progressing" || op?.phase === "Running" ? wait(app) : `kubectl -n argocd get application ${name} -o yaml로 원인을 본다`);
    },
  };
}

function appSteps(ctx: ReadCtx, app: string, main: string): Step[] {
  const ns = `app-${app}`;
  const valuesText = ctx.repo.readFile(`apps/${app}/values.yaml`, main);
  const imageText = ctx.repo.readFile(`apps/${app}/image.yaml`, main);
  const dataText = ctx.repo.readFile(`data/${app}/values.yaml`, main);
  const v = obj(valuesText);
  const d = obj(dataText);
  const usesPg = v.uses?.postgres === true || d.postgres?.enabled === true;
  const persistent = d.valkey?.persistent === true;
  const usesValkey = v.uses?.valkey === true || persistent;
  const want = digestOf(imageText);

  const steps: Step[] = [
    {
      id: "registered",
      target: `등록 apps/${app}/`,
      async read() {
        if (valuesText === null) return bad(dataText === null ? "등록 안 됨" : "등록 안 됨(데이터만 남음)", dataText === null ? `homelab app add ${app}` : "homelab data list", "missing");
        return ok(`revision ${(/^revision: ([0-9a-f]{7})/m.exec(imageText ?? "")?.[1]) ?? "?"}${/^hold: true$/m.test(imageText ?? "") ? " (hold: 롤백 고정)" : ""}`);
      },
    },
    {
      id: "build",
      target: `빌드 ukyi-app/${app}`,
      async read(c) {
        const run = ghList(c, `repos/ukyi-app/${app}/actions/runs?branch=main&per_page=1`, "앱 저장소 빌드 기록", "workflow_runs")[0];
        if (!run) return ok("기록 없음");
        if (run.status !== "completed") return ok(`${run.status} run #${run.run_number}`);
        return run.conclusion === "success" ? ok(`성공 run #${run.run_number}`) : bad(`${run.conclusion} run #${run.run_number}`, `gh run view -R ukyi-app/${app} ${run.id} --log-failed`);
      },
    },
    {
      id: "deploy-pr",
      target: "배포 PR",
      async read(c) {
        const open = ghList(c, `repos/ukyi-app/homelab/pulls?head=${encodeURIComponent(`ukyi-app:deploy/${app}`)}&state=open`, "열린 배포 PR")[0];
        return ok(open ? `#${open.number} 열림(자동 병합 대기)` : "없음");
      },
    },
  ];
  if (valuesText === null) return steps;

  steps.push(argoRow(app, app));
  if (dataText !== null) steps.push(argoRow(`${app}-data`, app));
  steps.push({
    id: "pods",
    target: "파드",
    async read(c) {
      if (v.suspended === true) return ok("멈춤(suspended, 복원 중)");
      const pods = c.k8s.list("pod", ns, `homelab.ukyi.app/app=${app}`).filter((p: any) => !p?.metadata?.ownerReferences?.some((o: any) => o?.kind === "Job"));
      const isReady = (p: any) => (p?.status?.conditions ?? []).some((x: any) => x?.type === "Ready" && x?.status === "True");
      const readyPods = pods.filter(isReady);
      if (pods.length === 0) return bad("파드 없음", wait(app), "missing");
      const ids = readyPods.flatMap((p: any) => (p?.status?.containerStatuses ?? []).map((s: any) => String(s?.imageID ?? "")));
      const match = want !== null && ids.length > 0 && ids.every((id: string) => id.endsWith(`@${want}`));
      if (readyPods.length !== pods.length) return bad(`${readyPods.length}/${pods.length} Ready`, `homelab logs ${app}`);
      return match ? ok(`${readyPods.length}/${pods.length} Ready, imageID = image.yaml`) : bad(`${readyPods.length}/${pods.length} Ready, imageID가 image.yaml과 다름`, wait(app));
    },
  });
  steps.push({
    id: "secrets",
    target: "시크릿(ExternalSecret)",
    async read(c) {
      // DB 역할 ExternalSecret이 아직 없으면(데이터 Application 전) 빼지 않고 준비 안 됨으로 센다.
      const role = usesPg ? (c.k8s.get("externalsecret", "database", `pg-role-${app}`) ?? { metadata: { name: `pg-role-${app}`, namespace: "database" } }) : null;
      const list = [...c.k8s.list("externalsecret", ns), ...(role ? [role] : [])];
      const notReady = list.filter((e: any) => !ready(e));
      if (notReady.length === 0) return ok(`${list.length}/${list.length} Ready`);
      // 시나리오 6: 빠진 키를 이름으로 보인다(값은 보지 않는다).
      const keys: string[] = Array.isArray(v.secrets) ? v.secrets : [];
      const have = keys.length && c.infisical.folderExists(`/apps/${app}`) ? c.infisical.listKeys(`/apps/${app}`) : [];
      const lost = keys.filter((k) => !have.includes(k));
      const names = notReady.map((e: any) => e?.metadata?.name).join(", ");
      if (lost.length) return bad(`${list.length - notReady.length}/${list.length} Ready: ${names}. Infisical에 없음: ${lost.join(", ")}`, `homelab secret set ${app} ${lost[0]}`);
      const first = notReady[0];
      return bad(`${list.length - notReady.length}/${list.length} Ready: ${names}`, `kubectl -n ${first?.metadata?.namespace ?? ns} describe externalsecret ${first?.metadata?.name}`);
    },
  });
  if (usesPg) {
    steps.push({
      id: "postgres",
      target: "PostgreSQL",
      async read(c) {
        const role = c.k8s.get("databaserole", "database", app);
        const db = c.k8s.get("database", "database", app);
        if (!role || !db) return bad(`${role ? "" : "역할 "}${db ? "" : "DB "}없음`, `데이터 Application ${app}-data가 동기화될 때까지 기다린다. ${wait(app)}`, "missing");
        if (role.status?.applied !== true || db.status?.applied !== true) return bad(`적용 전: ${short(role.status?.message ?? db.status?.message ?? "")}`, wait(app));
        if (!v.migration) return ok(`역할·DB ${app} 적용됨`);
        const job = c.k8s.get("job", ns, `${app}-migrate`);
        if (!job) return ok(`역할·DB ${app} 적용됨, 마이그레이션 Job 없음(다음 sync에 생긴다)`);
        if ((job.status?.succeeded ?? 0) > 0) return ok(`역할·DB ${app} 적용됨, 마이그레이션 성공`);
        if ((job.status?.failed ?? 0) > 0) return bad("마이그레이션 Job 실패", `homelab logs ${app} --job migrate`);
        return bad("마이그레이션 Job 진행 중", wait(app));
      },
    });
  }
  if (usesValkey) {
    steps.push({
      id: "valkey",
      target: "Valkey",
      async read(c) {
        const dep = c.k8s.get("deployment", ns, `${app}-valkey`);
        const kind = persistent ? "영속" : "캐시";
        if (persistent && d.valkey?.running === false) return ok("영속, 내려 둠(복원 중)");
        if (!dep) return bad(`${kind} 서버 없음`, wait(app), "missing");
        if ((dep.status?.availableReplicas ?? 0) < 1) return bad(`${kind} 서버 준비 안 됨`, wait(app));
        if (!persistent) return ok("캐시 준비됨");
        const cron = c.k8s.get("cronjob", ns, `${app}-valkey-backup`);
        if (!cron) return bad("영속 준비됨, 백업 CronJob 없음", `kubectl -n argocd get application ${app}-data -o yaml로 원인을 본다`, "missing");
        const last = cron.status?.lastSuccessfulTime;
        return ok(`영속 준비됨, 마지막 백업 ${last ?? "없음(첫 백업은 03:30 KST)"}`);
      },
    });
  }
  const host = typeof v.public?.host === "string" ? v.public.host : null;
  if (host) {
    steps.push({
      id: "public",
      target: `공개 https://${host}`,
      async read(c) {
        const code = c.web.publicStatus(host, "/healthz");
        return code === 200 ? ok("/healthz 200") : bad(`/healthz ${code}`, wait(app));
      },
    });
  }
  return steps;
}

// 전체 보기는 apps/와 data/를 함께 연다. 앱 없이 데이터만 남은 것(예 data/homelab-probe2)과 <app>-data 장애를
// 놓치지 않는다(#884 리뷰 P2-4). 이름 순으로 <app>, <app>-data.
function dirs(ctx: ReadCtx, main: string, dir: "apps" | "data"): string[] {
  const r = ctx.gh.get(`repos/ukyi-app/homelab/contents/${dir}?ref=${main}`);
  if (r.status === 404) return [];
  if (r.status !== 200 || !Array.isArray(r.json)) throw new Error(`${dir}/ 목록: HTTP ${r.status}`);
  return r.json.filter((e: any) => e?.type === "dir").map((e: any) => String(e.name));
}

function overviewSteps(ctx: ReadCtx, main: string): Step[] {
  const apps = dirs(ctx, main, "apps");
  const data = dirs(ctx, main, "data");
  return [...new Set([...apps, ...data])].sort().flatMap((a) => [...(apps.includes(a) ? [argoRow(a, a)] : []), ...(data.includes(a) ? [argoRow(`${a}-data`, a)] : [])]);
}

function platformSteps(): Step[] {
  return [
    {
      id: "platform-apps",
      target: "플랫폼 Application(project platform)",
      async read(c) {
        const apps = c.k8s.list("application", "argocd").filter((a: any) => a?.spec?.project === "platform");
        const badOnes = apps.filter((a: any) => !(a?.status?.sync?.status === "Synced" && a?.status?.health?.status === "Healthy"));
        if (badOnes.length === 0) return ok(`${apps.length}개 Synced·Healthy`);
        return bad(badOnes.map((a: any) => `${a.metadata?.name} ${a.status?.sync?.status}·${a.status?.health?.status}`).join(", "), `kubectl -n argocd get application ${badOnes[0].metadata?.name} -o yaml로 원인을 본다`);
      },
    },
    {
      id: "nodes",
      target: "노드",
      async read(c) {
        const nodes = c.k8s.list("node", null);
        const notReady = nodes.filter((n: any) => !ready(n)).map((n: any) => n?.metadata?.name);
        return notReady.length ? bad(`Ready 아님: ${notReady.join(", ")}`, "kubectl describe node로 원인을 본다") : ok(`${nodes.length}개 Ready`);
      },
    },
    {
      id: "postgres-cluster",
      target: "CNPG Cluster database/pg",
      async read(c) {
        const pg = c.k8s.get("cluster", "database", "pg");
        if (!pg) return bad("없음", "kubectl -n argocd get application cnpg-cluster", "missing");
        return pg.status?.phase === "Cluster in healthy state" ? ok(pg.status.phase) : bad(String(pg.status?.phase ?? "?"), "kubectl -n database describe cluster pg");
      },
    },
    {
      id: "secret-stores",
      target: "ClusterSecretStore",
      async read(c) {
        const stores = c.k8s.list("clustersecretstore", null);
        const notReady = stores.filter((s: any) => !ready(s)).map((s: any) => s?.metadata?.name);
        return notReady.length ? bad(`Ready 아님: ${notReady.join(", ")}`, "Infisical 자격을 본다(rotate.md 1절)") : ok(`${stores.length}개 Ready`);
      },
    },
  ];
}

export default defineCommand({
  path: ["status"],
  summary: "빌드·배포 PR·Argo CD·DB·시크릿 준비 상태와 다음 행동",
  kind: "read",
  args: [{ name: "app", required: false, help: "앱 이름", pattern: APP_NAME }],
  flags: [{ name: "platform", kind: "bool", help: "플랫폼 구성 요소 상태" }],
  async run(ctx, input) {
    const app = input.args.app;
    const main = ctx.repo.mainSha();
    const steps = [...(app ? appSteps(ctx, app, main) : input.flags.platform ? [] : overviewSteps(ctx, main)), ...(input.flags.platform ? platformSteps() : [])];
    return ctx.engine({ command: "status", app, title: app ? `homelab status ${app}` : "homelab status", steps });
  },
});
