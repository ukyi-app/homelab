// homelab cache restore <app> [--object <dump-…rdb>] [--backup-first] | --finish | --abort
// 영속 Valkey 하나 복원(설계 C.5.6, restore.md 1절, G 시나리오 4, 결정 D1).
//
// 순서(restore.md 1절): (0 수동 백업) → 1 서버 내림 PR → 2 복원 Job(RDB를 dump.rdb로, appendonlydir 지움) →
// 3 복원 모드로 올림 PR(appendonly no로 RDB를 읽는다) → 4 CONFIG SET appendonly yes → 5 복원 모드 끄기 PR, rollout restart → 6 정리.
// 함정: appendonly yes인 채 appendonlydir만 지우면 Valkey 9.1.2는 RDB를 읽지 않고 빈 데이터로 뜬다(U18). 그래서 복원 모드가 있다.
// 멈춘 단계에서 다시 시작하려고 실행 기록을 앱 ns의 ConfigMap restore-vk에 둔다(restore.md의 $W를 클러스터에, REPORT-ops 2절).
// 복원 Job 이름은 실행과 무관하게 restore-vk 하나라 API 서버의 이름 유일성이 같은 PVC의 두 번째 쓰기를 막는다(restore.md 1절 2).
// 끝나도 기록은 남기고(재실행이 모두 same) --finish가 지운다.
import { defineCommand, type Observation, type ReadCtx, type RestoreRecord, type Step, type WriteCtx } from "../core/command";
import { APP_NAME, newRunId } from "../core/names";
import { prStep } from "../core/pr";
import { UsageError } from "../core/result";
import { parseYaml, setTopLevel } from "../core/values";

const RECORD = "restore-vk";
const JOB = "restore-vk";
const LABEL = "homelab.ukyi.app/restore";
const OBJECT = /latest|dump-[0-9]{8}T[0-9]{6}Z\.rdb/;
const DIGEST_IMAGE = /^[a-z0-9./_-]+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$/;
const BUCKET = /^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$/;
// KEEP: 엔진은 Plan.next가 undefined를 내면 기본 다음 행동을 쓴다(engine.ts finish). 타입은 string | null이라 맞춰 둔다.
const KEEP = undefined as unknown as string | null;

const same = (detail: string, extra: Partial<Observation> = {}): Observation => ({ state: "same", action: "none", detail, ...extra });
// 앞 단계가 끝나기 전에는 apply 순서상 여기 오지 않는다. plan에서만 보이는 "예정".
const later = (detail: string): Observation => ({ state: "missing", action: "none", detail });

type Names = { app: string; ns: string; server: string; cronjob: string; dataFile: string };

function values(ctx: ReadCtx | WriteCtx, path: string): any | null {
  const text = ctx.repo.readFile(path);
  return text === null ? null : parseYaml(text);
}

const record = (ctx: ReadCtx | WriteCtx, n: Names): RestoreRecord | null => ctx.k8s.restoreRecord(n.ns, RECORD);
const has = (r: RestoreRecord | null, key: string) => r?.data[key] === "1";

function mine(w: WriteCtx, n: Names): RestoreRecord {
  const r = record(w, n);
  if (!r) throw new Error(`실행 기록 ${n.ns}/${RECORD}이 없다`);
  return r;
}

function mark(w: WriteCtx, n: Names, set: Record<string, string | null>): void {
  w.k8s.restoreRecordUpdate(n.ns, RECORD, mine(w, n).run, set);
}

const hasTrue = (o: any, type: string) => (o?.status?.conditions ?? []).some((c: any) => c?.type === type && c?.status === "True");
const mountsData = (spec: any) => (spec?.volumes ?? []).some((v: any) => v?.persistentVolumeClaim?.claimName === "valkey-data");

// valkey-data를 마운트하는 끝나지 않은 Job과 그 파드(서버 파드는 Job 파드가 아니라 빠진다). 복원 Job의 흔적이다.
function restoreUsers(ctx: ReadCtx | WriteCtx, n: Names): string[] {
  const pods = ctx.k8s.list("pod", n.ns).filter((p) => typeof p?.metadata?.labels?.["job-name"] === "string" && p?.status?.phase !== "Succeeded" && p?.status?.phase !== "Failed" && mountsData(p?.spec)).map((p) => `pod/${p.metadata?.name}`);
  const jobs = ctx.k8s.list("job", n.ns).filter((j) => !hasTrue(j, "Complete") && !hasTrue(j, "Failed") && mountsData(j?.spec?.template?.spec)).map((j) => `job/${j.metadata?.name}`);
  return [...pods, ...jobs];
}

// 이 실행의 Job·파드(지우는 중 포함). 기록을 지우기 직전에 0개여야 한다.
// 함정: CronJob에서 만든 수동 백업 Job은 Job에만 실행 라벨이 있고 파드 템플릿에는 없다(core createJobFromCronJob, 차트의 백업
// 템플릿에도 없다). 그래서 기록해 둔 백업 Job 이름마다 Kubernetes가 붙이는 job-name 라벨로 파드를 따로 찾는다(#883 r2 P2-3).
function runObjects(ctx: ReadCtx | WriteCtx, n: Names, r: RestoreRecord): string[] {
  const out = [...ctx.k8s.list("job", n.ns, `${LABEL}=${r.run}`).map((j) => `job/${j.metadata?.name}`), ...ctx.k8s.list("pod", n.ns, `${LABEL}=${r.run}`).map((p) => `pod/${p.metadata?.name}`)];
  for (const job of backupJobs(r)) {
    for (const p of ctx.k8s.list("pod", n.ns, `job-name=${job}`)) out.push(`pod/${p.metadata?.name}`);
    if (ctx.k8s.get("job", n.ns, job)) out.push(`job/${job}`);
  }
  return [...new Set(out)];
}

const BACKUP_JOB = /^backup-[a-z0-9]{1,22}-[0-9a-f]{4}$/;

function backupJobs(r: RestoreRecord): string[] {
  const names = (r.data["backup.jobs"] ?? "").split(",").filter(Boolean);
  if (names.some((x) => !BACKUP_JOB.test(x))) throw new Error("실행 기록의 backup.jobs 형식이 아니다");
  return names;
}

// 기록이 없을 때 남은 복원 흔적. Git의 복원 설정, 복원 Job, valkey-data를 쓰는 Job 파드. 서버가 안 떠 있는 것은 흔적이 아니다
// (AOF 손상처럼 서버 장애를 복원으로 고치려는 경우다, #883 r2 P2-4).
function traces(ctx: ReadCtx | WriteCtx, n: Names): string[] {
  const v = values(ctx, n.dataFile)?.valkey ?? {};
  const left: string[] = [];
  if ("running" in v || "restoreMode" in v) left.push(`${n.dataFile}에 running·restoreMode`);
  if (ctx.k8s.get("job", n.ns, JOB)) left.push(`job/${JOB}`);
  left.push(...restoreUsers(ctx, n));
  return left;
}

// 서버가 내려가 있지 않은 이유(빈 배열이면 내려감). main의 running: false, Deployment 없음, PVC 있음, CronJob suspend.
// 파드 0개는 증거가 아니다. Deployment가 다시 생겼으면 곧 파드를 만든다(#883 r3 P1-2).
function serverUp(ctx: ReadCtx | WriteCtx, n: Names): string[] {
  const left: string[] = [];
  if (values(ctx, n.dataFile)?.valkey?.running !== false) left.push(`main ${n.dataFile}에 running: false 없음`);
  if (ctx.k8s.get("deployment", n.ns, n.server)) left.push(`deployment/${n.server} 있음`);
  if (!ctx.k8s.get("pvc", n.ns, "valkey-data")) left.push("pvc/valkey-data 없음");
  if (ctx.k8s.get("cronjob", n.ns, n.cronjob)?.spec?.suspend !== true) left.push(`cronjob/${n.cronjob} suspend 아님`);
  return left;
}

function rolledOut(d: any): boolean {
  const want = d?.spec?.replicas ?? 1;
  return want >= 1 && d?.status?.updatedReplicas === want && d?.status?.readyReplicas === want && (d?.status?.observedGeneration ?? 0) >= (d?.metadata?.generation ?? 0);
}

// data values의 valkey 블록만 고친다(다른 키·주석은 그대로, core/values).
function valkeyEdit(n: Names, change: (v: Record<string, unknown>) => Record<string, unknown>) {
  return (cur: Record<string, string | null>) => {
    const text = cur[n.dataFile];
    if (text === null) throw new Error(`${n.dataFile}가 없다`);
    const v: any = parseYaml(text);
    return { [n.dataFile]: setTopLevel(text, { valkey: change({ ...(v?.valkey ?? {}) }) }) };
  };
}

function holdPr(id: string, step: Step): Step {
  return {
    ...step,
    id,
    async read(ctx) {
      const o = await step.read(ctx);
      return o.state === "same" && o.wait ? { ...o, hold: o.wait, wait: undefined } : o;
    },
  };
}

// 기록의 pre가 있어야 시작하고 done이 있으면 끝난 PR 단계. 끝난 PR을 main의 지금 내용과 다시 비교하면
// 뒤 단계의 PR(예 running: true)이 앞 PR(running: false)과 달라 보여 다시 연다.
function gatedPr(n: Names, id: string, pre: string | null, done: string, step: Step): Step {
  const inner = holdPr(id, step);
  return {
    ...inner,
    async read(ctx) {
      const r = record(ctx, n);
      if (has(r, done)) return same("끝남");
      if (pre && !has(r, pre)) return later(`앞 단계 뒤 ${step.target}`);
      return inner.read(ctx);
    },
  };
}

// 키 수가 같기를 요구하지 않는다. 복원 모드로 올린 뒤 사람이 PR을 병합할 때까지 앱이 돌며 키를 바꾸고 TTL 키도 만료된다.
// 같기를 요구하면 정상 변경을 손실로 보고, touched 때문에 --abort도 안 돼 실행이 갇힌다(#883 Connector P2).
// 아는 실패는 빈 데이터(U18)라, 기준들 중 하나라도 양수인데 지금 0개면 멈춘다. 기준은 저장된 값과 바로 앞에서 새로 본 값
// 둘 다다. 저장된 0만 믿으면 그 뒤 생긴 키를 다 잃어도 통과한다(#889 r2 P1-2).
function emptied(before: number[], after: number): boolean {
  return before.some((x) => x > 0) && after === 0;
}

// 0개를 본 실행은 기록에 suspect.empty를 남긴다. 재실행이 빈 서버의 0개를 새 기준으로 받아 성공으로 넘어가지 않게 한다
// (#889 r1 P1-3). 앱이 정상적으로 다 지웠거나 TTL로 모두 만료됐으면(#889 r1 P2) 사람이 보고 --accept-empty로 받아들인다.
// 플래그는 이 표식이 있을 때만 쓰인다(미리 붙여 두어 검사를 끄지 못하게). 받아들이면 그 빈 상태가 새 기준(0)이 되고 표식은
// 지운다. 승인은 그 관측에만 쓰인다: 뒤에 키가 생겼다가 다시 0이 되면 바로 앞에서 본 양수 때문에 다시 멈춘다(#889 r2 P1-1).
// empty.accepted는 받아들인 횟수 기록일 뿐 검사를 끄지 않는다.
function acceptEmpty(w: WriteCtx, n: Names, flag: boolean): boolean {
  const r = mine(w, n);
  if (!flag || !has(r, "suspect.empty")) return false;
  mark(w, n, { "suspect.empty": null, "empty.accepted": String(Number(r.data["empty.accepted"] ?? "0") + 1), "dbsize.base": "0", "dbsize.pre": "0" });
  return true;
}

// 앱 키 수(복원 표식 키는 뺀다)와 표식 유무.
function appKeys(w: WriteCtx, n: Names, run: string): { appendonly: string; keys: number; marker: boolean } {
  const s = valkeyServer(w, n);
  const marker = w.valkey.marker(n.ns, n.server, run, "exists");
  return { appendonly: s.appendonly, keys: s.dbsize - (marker ? 1 : 0), marker };
}

// 표식 키가 없으면 복원한 데이터가 그대로라는 근거가 없다. 키 수로는 "복원 키가 다 사라지고 앱이 새 키를 썼다"를 못 가린다.
// --accept-empty로 넘길 수 없다(손으로 본다).
function markerLost(w: WriteCtx, n: Names, when: string): never {
  mark(w, n, { "suspect.marker": "1" });
  throw new Error(`${when} 복원 표식 키 homelab:restore:${mine(w, n).run}이 없다. 복원한 데이터를 잃었을 수 있다. 손으로 확인한다(restore.md 1절, --accept-empty로 넘길 수 없다)`);
}

function suspectEmpty(w: WriteCtx, n: Names, message: string): never {
  mark(w, n, { "suspect.empty": "1" });
  throw new Error(`${message}. 데이터를 확인하고, 비어 있는 것이 정상이면 같은 명령에 --accept-empty를 붙여 다시 한다`);
}

function valkeyServer(w: WriteCtx, n: Names): { appendonly: string; dbsize: number } {
  const ao = w.valkey.cli(n.ns, n.server, "CONFIG GET appendonly").trim().split(/\s+/).at(-1) ?? "";
  const size = Number(w.valkey.cli(n.ns, n.server, "DBSIZE").trim());
  if (!Number.isInteger(size) || size < 0) throw new Error("DBSIZE를 읽지 못했다");
  return { appendonly: ao, dbsize: size };
}

// restore.md 1절 2단계의 Job 그대로. 이미지·버킷은 그 앱의 백업 CronJob(upload 컨테이너)에서 읽는다(차트와 같은 버전을 쓴다).
function restoreJob(n: Names, run: string, object: string, image: string, bucket: string): Record<string, unknown> {
  const script = [
    "set -eu",
    'dir="r2:${BUCKET}/valkey/${APP}"',
    'obj="${OBJECT}"',
    '[ "$obj" = latest ] && obj="$(rclone lsf "$dir" | sort | tail -1)"',
    '[ -n "$obj" ] || { echo "백업이 없다: $dir" >&2; exit 1; }',
    'echo "받음: $dir/$obj"',
    'rclone copyto "$dir/$obj" /data/dump.rdb.new',
    "test -s /data/dump.rdb.new",
    "rm -rf /data/appendonlydir",
    "mv /data/dump.rdb.new /data/dump.rdb",
    "ls -la /data",
    "",
  ].join("\n");
  const r2 = (name: string, key: string) => ({ name, valueFrom: { secretKeyRef: { name: `${n.app}-valkey-backup-r2`, key } } });
  return {
    apiVersion: "batch/v1",
    kind: "Job",
    metadata: { name: JOB, namespace: n.ns, labels: { [LABEL]: run } },
    spec: {
      backoffLimit: 0,
      activeDeadlineSeconds: 900,
      template: {
        // 백업 Job의 NetworkPolicy(<앱>-valkey-backup, R2 443과 DNS)를 같이 쓴다.
        metadata: { labels: { [LABEL]: run, "homelab.ukyi.app/role": "valkey-backup" } },
        spec: {
          restartPolicy: "Never",
          automountServiceAccountToken: false,
          // 서버가 uid 1000으로 쓴 파일을 지워야 한다(local-retain hostPath PV에는 fsGroup이 적용되지 않는다).
          securityContext: { runAsNonRoot: true, runAsUser: 1000, runAsGroup: 1000, seccompProfile: { type: "RuntimeDefault" } },
          containers: [
            {
              name: "restore",
              image,
              command: ["/bin/sh", "-c"],
              args: [script],
              env: [
                { name: "APP", value: n.app },
                { name: "BUCKET", value: bucket },
                { name: "OBJECT", value: object },
                { name: "HOME", value: "/tmp" },
                { name: "RCLONE_CONFIG_R2_TYPE", value: "s3" },
                { name: "RCLONE_CONFIG_R2_PROVIDER", value: "Cloudflare" },
                { name: "RCLONE_CONFIG_R2_REGION", value: "auto" },
                { name: "RCLONE_CONFIG_R2_NO_CHECK_BUCKET", value: "true" },
                r2("RCLONE_CONFIG_R2_ACCESS_KEY_ID", "R2_ACCESS_KEY_ID"),
                r2("RCLONE_CONFIG_R2_SECRET_ACCESS_KEY", "R2_SECRET_ACCESS_KEY"),
                r2("RCLONE_CONFIG_R2_ENDPOINT", "R2_ENDPOINT"),
              ],
              resources: { requests: { cpu: "10m", memory: "64Mi" }, limits: { memory: "64Mi" } },
              securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: ["ALL"] } },
              volumeMounts: [
                { name: "data", mountPath: "/data" },
                { name: "tmp", mountPath: "/tmp" },
              ],
            },
          ],
          volumes: [
            { name: "data", persistentVolumeClaim: { claimName: "valkey-data" } },
            { name: "tmp", emptyDir: { sizeLimit: "16Mi" } },
          ],
        },
      },
    },
  };
}

function uploadContainer(ctx: ReadCtx | WriteCtx, n: Names): { image: string; bucket: string } {
  const cj = ctx.k8s.get("cronjob", n.ns, n.cronjob);
  const c = (cj?.spec?.jobTemplate?.spec?.template?.spec?.containers ?? []).find((x: any) => x?.name === "upload");
  const bucket = (c?.env ?? []).find((e: any) => e?.name === "BUCKET")?.value;
  if (typeof c?.image !== "string" || !DIGEST_IMAGE.test(c.image)) throw new Error(`CronJob ${n.cronjob}의 upload 이미지가 digest로 고정돼 있지 않다`);
  if (typeof bucket !== "string" || !BUCKET.test(bucket)) throw new Error(`CronJob ${n.cronjob}의 BUCKET을 읽지 못했다`);
  return { image: c.image, bucket };
}

function jobFinished(w: WriteCtx, n: Names): string {
  const log = w.k8s.logs(n.ns, { job: JOB }, { container: "restore", tail: 50 });
  const got = /^받음: (r2:[a-z0-9-]+\/valkey\/[a-z0-9-]+\/dump-[0-9]{8}T[0-9]{6}Z\.rdb)$/m.exec(log)?.[1];
  if (!got) throw new Error(`복원 Job 로그에 받은 객체가 없다(kubectl -n ${n.ns} logs job/${JOB})`);
  return got;
}

function mainSteps(n: Names, object: string, backupFirst: boolean, acceptFlag: boolean): Step[] {
  const app = n.app;
  const steps: Step[] = [
    {
      id: "registered",
      target: `영속 Valkey ${app}`,
      async read(ctx) {
        if (values(ctx, n.dataFile)?.valkey?.persistent !== true) return { state: "missing", action: "none", detail: `data/${app}에 valkey.persistent가 없다(캐시 Valkey는 복원하지 않는다)`, next: `homelab cache add ${app} --persistent` };
        if (!ctx.k8s.get("cronjob", n.ns, n.cronjob)) return { state: "missing", action: "none", detail: `CronJob ${n.cronjob} 없음`, next: `homelab status ${app}` };
        uploadContainer(ctx, n);
        return same("백업 CronJob 있음");
      },
    },
    {
      id: "other-runs",
      target: "다른 복원",
      async read(ctx) {
        const r = record(ctx, n);
        const opt = backupFirst ? "1" : "0";
        // 실행 옵션은 기록에 고정한다. 끝난 실행에 --backup-first를 붙여 다시 치면 정리 뒤에 새 Job이 생긴다(#883 r1 P1-3).
        if (r && (r.data.object !== object || (r.data["opt.backup"] ?? "") !== opt)) return { state: "differs", action: "none", detail: `다른 복원(실행 ${r.run}, 객체 ${r.data.object}, 수동 백업 ${r.data["opt.backup"] === "1" ? "함" : "안 함"})이 남아 있다`, next: `같은 옵션으로 잇거나 homelab cache restore ${app} --finish 또는 --abort` };
        const job = ctx.k8s.get("job", n.ns, JOB);
        if (job && job.metadata?.labels?.[LABEL] !== r?.run) return { state: "differs", action: "none", detail: `다른 실행의 Job ${JOB}이 있다`, next: `kubectl -n ${n.ns} get job,pod -L ${LABEL}로 보고, 끝났으면 로그를 남긴 뒤 지운다` };
        if (r) return same(`이 복원(실행 ${r.run})을 잇는다`);
        // 기록이 없으면 처음 상태여야 한다. 기록만 지워진 진행 중 복원을 새 실행으로 처음부터 다시 하지 않는다(PVC를 또 덮는다).
        const left = traces(ctx, n);
        if (left.length) return { state: "differs", action: "none", detail: `실행 기록 없이 복원 흔적이 있다(${left.join(", ")})`, next: `kubectl -n ${n.ns} get deploy,job,pod -L ${LABEL}와 ${n.dataFile}를 손으로 확인한다(restore.md 1절)` };
        return same("없음, 복원 흔적 없음");
      },
    },
    {
      id: "lock",
      target: `실행 기록 ${n.ns}/${RECORD}`,
      async read(ctx) {
        const r = record(ctx, n);
        return r ? same(`실행 ${r.run}`) : { state: "missing", action: "create", detail: `없음 → 새 실행(객체 ${object})` };
      },
      async apply(w) {
        if (w.k8s.restoreRecordCreate(n.ns, RECORD, newRunId(), { object, "opt.backup": backupFirst ? "1" : "0" }) === "exists") throw new Error("그사이 다른 실행이 기록을 만들었다. 다시 실행해 상태를 읽는다");
      },
    },
  ];
  if (backupFirst) {
    steps.push({
      id: "backup",
      target: "수동 백업(0단계)",
      async read(ctx) {
        const r = record(ctx, n);
        if (has(r, "ok.backup")) return same(`올림: ${r!.data.backup}`);
        return { state: "missing", action: "create", detail: `CronJob ${n.cronjob}에서 Job 하나 → R2에 올림` };
      },
      async apply(w) {
        const run = mine(w, n).run;
        // 시도마다 새 이름(restore.md 0.1: 실패한 시도의 로그를 지우지 않고 남긴다).
        const job = `backup-${run}-${newRunId().slice(-4)}`;
        // 만들기 전에 이름을 남긴다. 만들기 결과가 미상이어도 정리·재확인이 그 이름으로 파드를 찾는다.
        mark(w, n, { "ok.cleanup": null, "backup.jobs": [...backupJobs(mine(w, n)), job].join(",") });
        w.k8s.createJobFromCronJob(n.ns, n.cronjob, job, run);
        if (!w.k8s.waitCondition("job", n.ns, { name: job }, "complete", 600)) throw new Error(`수동 백업 Job ${job}이 10분 안에 끝나지 않았다(kubectl -n ${n.ns} logs job/${job} --all-containers)`);
        const up = /^올림: (r2:[a-z0-9-]+\/valkey\/[a-z0-9-]+\/dump-[0-9]{8}T[0-9]{6}Z\.rdb)$/m.exec(w.k8s.logs(n.ns, { job }, { container: "upload", tail: 20 }))?.[1];
        if (!up) throw new Error(`수동 백업 Job ${job} 로그에 올린 객체가 없다`);
        mark(w, n, { "ok.backup": "1", backup: up });
      },
    });
  }
  steps.push(
    gatedPr(
      n,
      "pr-down",
      backupFirst ? "ok.backup" : null,
      "ok.down",
      prStep({
        command: "cache restore",
        app,
        title: `cache restore ${app}: Valkey 서버 내림`,
        body: `\`homelab cache restore ${app}\` 1단계(restore.md 1절). \`valkey.running: false\`: 서버 Deployment를 내리고 PVC \`valkey-data\`는 남기고 백업 CronJob은 suspend한다. 앱은 Valkey 오류를 내지만 계속 돈다.`,
        files: [n.dataFile],
        edit: valkeyEdit(n, (v) => {
          delete v.restoreMode;
          return { ...v, running: false };
        }),
      }),
    ),
    {
      id: "down",
      target: `서버 ${n.server} 내림`,
      async read(ctx) {
        const r = record(ctx, n);
        if (!r) return later("서버 내림 PR 병합 뒤 확인");
        // 복원 Job을 새로 만들 차례면 ok.down이 있어도 지금 다시 본다. 그만두기(--abort) PR이 병합됐거나 누가 서버를 올렸으면
        // 옛 표식만 믿고 서버와 복원 Job이 같은 PVC를 쓰게 된다(#883 r3 P1-2). 이미 있는 Job은 기다리기만 해 새로 만들지 않는다.
        if (has(r, "ok.down") && (has(r, "ok.job") || ctx.k8s.get("job", n.ns, JOB))) return same("내려감");
        const up = serverUp(ctx, n);
        if (has(r, "ok.down")) return up.length ? { state: "differs", action: "update", detail: `서버 내림을 기록했지만 지금은 아니다(${up.join(", ")}) → 표식을 지우고 서버 내림 PR부터 다시` } : same("내려감(다시 확인)");
        return up.length ? same("PR 병합됨", { hold: "서버 내림 PR 병합·Argo CD 반영 대기" }) : { state: "differs", action: "update", detail: "Deployment 없음, PVC 남음, CronJob suspend → 기록" };
      },
      async apply(w) {
        const up = serverUp(w, n);
        // 표식을 지우면 다음 실행에서 서버 내림 PR(running: false)이 다시 열리고, 반영을 확인한 뒤에야 복원 Job으로 간다.
        mark(w, n, { "ok.down": up.length ? null : "1" });
      },
    },
    {
      id: "restore-job",
      target: `Job ${n.ns}/${JOB}`,
      async read(ctx) {
        const r = record(ctx, n);
        if (has(r, "ok.job")) return same(`받음: ${r!.data.got}`);
        if (!has(r, "ok.down")) return later(`서버를 내린 뒤 R2 ${object} → dump.rdb, appendonlydir 지움`);
        return { state: "missing", action: "create", detail: `R2 ${object} → dump.rdb, appendonlydir 지움` };
      },
      async apply(w) {
        const run = mine(w, n).run;
        // touched: Job이 appendonlydir을 지운 뒤 실패하거나 로그·기록 저장이 실패해 ok.job이 없어도, 사람이 Job을 지워도 PVC는
        // 이미 바뀌었을 수 있다. 이 표식이 있으면 --abort를 거부한다(#883 r1 P1-1). 읽기 사전 검사가 실패하면 남기지 않는다.
        // 만들기를 요청하기 바로 전, 또는 이 실행의 Job이 이미 있음을 본 때에만 남긴다(#883 r2 P2-5).
        const existing = w.k8s.get("job", n.ns, JOB);
        if (existing) {
          if (existing.metadata?.labels?.[LABEL] !== run) throw new Error(`다른 실행의 Job ${JOB}이 있다`);
          mark(w, n, { touched: "1", "ok.cleanup": null });
          if (hasTrue(existing, "Failed")) throw new Error(`앞 시도의 Job ${JOB}이 실패했다. 로그(kubectl -n ${n.ns} logs job/${JOB})를 남긴 뒤 지우고(kubectl -n ${n.ns} delete job ${JOB} --wait) 다시 실행한다`);
        } else {
          // 이 PVC를 쓰는(쓸) 파드·Job이 남아 있으면 멈춘다. 이름·라벨로 거르지 않는다(옛 이름의 Job, 아직 안 내려간 서버 파드도 걸리게).
          const pods = w.k8s.list("pod", n.ns).filter((p) => p?.status?.phase !== "Succeeded" && p?.status?.phase !== "Failed" && mountsData(p?.spec)).map((p) => `pod/${p.metadata?.name}`);
          const jobs = w.k8s.list("job", n.ns).filter((j) => !hasTrue(j, "Complete") && !hasTrue(j, "Failed") && mountsData(j?.spec?.template?.spec)).map((j) => `job/${j.metadata?.name}`);
          if (pods.length || jobs.length) throw new Error(`valkey-data를 쓰는 파드·Job이 남아 있다: ${[...pods, ...jobs].join(", ")}. 끝났는지 보고 지운 뒤 다시 한다`);
          // down 단계가 방금 봤어도 touched·Job 직전에 한 번 더 본다(#883 r3 P1-2).
          const up = serverUp(w, n);
          if (up.length) throw new Error(`서버가 내려가 있지 않다(${up.join(", ")}). 다시 실행하면 서버 내림부터 잇는다`);
          const { image, bucket } = uploadContainer(w, n);
          mark(w, n, { touched: "1", "ok.cleanup": null });
          w.k8s.createRestoreObject(n.ns, restoreJob(n, run, mine(w, n).data.object ?? object, image, bucket));
        }
        if (!w.k8s.waitCondition("job", n.ns, { name: JOB }, "complete", 900)) throw new Error(`복원 Job이 15분 안에 끝나지 않았다(kubectl -n ${n.ns} get job,pod -L ${LABEL})`);
        mark(w, n, { "ok.job": "1", got: jobFinished(w, n) });
      },
    },
    gatedPr(
      n,
      "pr-mode",
      "ok.job",
      "ok.loaded",
      prStep({
        command: "cache restore mode",
        app,
        title: `cache restore ${app}: 복원 모드로 올림`,
        body: `\`homelab cache restore ${app}\` 3단계(restore.md 1절). \`running: true\`와 \`restoreMode: true\`: 새 파드가 \`appendonly no\`로 떠 RDB를 읽는다.`,
        files: [n.dataFile],
        edit: valkeyEdit(n, (v) => ({ ...v, running: true, restoreMode: true })),
      }),
    ),
    {
      id: "loaded",
      target: "RDB 읽음(appendonly no)",
      async read(ctx) {
        const r = record(ctx, n);
        if (has(r, "ok.loaded")) return same(`키 ${r!.data.dbsize}개`);
        if (!has(r, "ok.job")) return later("복원 모드 PR 병합 뒤 키 수 확인");
        const d = ctx.k8s.get("deployment", n.ns, n.server);
        return d && rolledOut(d) ? { state: "differs", action: "update", detail: "서버 뜸 → appendonly no·키 수 기록" } : same("PR 병합됨", { hold: "Argo CD 반영 대기(복원 모드로 올림)" });
      },
      async apply(w) {
        if (!w.k8s.rolloutStatus(n.ns, n.server, 300)) throw new Error("Valkey rollout이 끝나지 않았다");
        const s = valkeyServer(w, n);
        // appendonly yes로 떴으면 RDB를 읽지 않고 빈 데이터다(U18). 여기서 멈춘다.
        if (s.appendonly !== "no") throw new Error(`복원 모드가 아니다(appendonly ${s.appendonly}). restoreMode가 반영됐는지 본다`);
        // RDB를 읽은 직후 표식 키를 넣는다. 재시작 뒤 이 키가 있어야 복원한 데이터가 AOF로 이어진 것이다(#889 r2 6).
        const run = mine(w, n).run;
        const keys = s.dbsize - (w.valkey.marker(n.ns, n.server, run, "exists") ? 1 : 0);
        w.valkey.marker(n.ns, n.server, run, "set");
        mark(w, n, { "ok.loaded": "1", dbsize: String(keys), marker: "1" });
      },
    },
    {
      id: "aof",
      target: "AOF 다시 켜기",
      async read(ctx) {
        const r = record(ctx, n);
        if (has(r, "ok.aof")) return same("aof_enabled:1, rewrite ok");
        if (!has(r, "ok.loaded")) return later("CONFIG SET appendonly yes → rewrite 완료 대기");
        return { state: "missing", action: "update", detail: "CONFIG SET appendonly yes → rewrite 완료 대기" };
      },
      async apply(w) {
        const r = mine(w, n);
        if (has(r, "suspect.empty") && !acceptEmpty(w, n, acceptFlag)) suspectEmpty(w, n, "앞 실행이 키 0개를 봤다");
        const cur = mine(w, n);
        const want = Number(cur.data["dbsize.base"] ?? cur.data.dbsize);
        const before = appKeys(w, n, r.run).keys;
        w.valkey.cli(n.ns, n.server, "CONFIG SET appendonly yes");
        if (!w.valkey.waitAof(n.ns, n.server, 300)) throw new Error("AOF rewrite가 300초 안에 끝나지 않았다");
        const s = appKeys(w, n, r.run);
        if (emptied([want, before], s.keys)) suspectEmpty(w, n, `키가 0개가 됐다(복원 직후 ${want}개, 켜기 직전 ${before}개)`);
        mark(w, n, { "ok.aof": "1" });
      },
    },
    gatedPr(
      n,
      "pr-normal",
      "ok.aof",
      "ok.reloaded",
      prStep({
        command: "cache restore normal",
        app,
        title: `cache restore ${app}: 복원 모드 끄기`,
        body: `\`homelab cache restore ${app}\` 5단계(restore.md 1절). \`running\`·\`restoreMode\` 줄을 지운다. ConfigMap만 바뀌고, 병합 뒤 CLI가 rollout restart로 AOF에서 다시 읽히는지 본다.`,
        files: [n.dataFile],
        edit: valkeyEdit(n, (v) => {
          delete v.running;
          delete v.restoreMode;
          return v;
        }),
      }),
    ),
    {
      id: "reloaded",
      target: "AOF에서 다시 읽음",
      async read(ctx) {
        const r = record(ctx, n);
        if (has(r, "ok.reloaded")) return same(`키 ${r!.data["dbsize.after"] ?? r!.data.dbsize}개(복원 직후 ${r!.data.dbsize}개)`);
        if (!has(r, "ok.aof")) return later("복원 모드 끄기 PR 병합 뒤 rollout restart·키 수 확인");
        const v = values(ctx, n.dataFile)?.valkey ?? {};
        const argo = ctx.k8s.get("application", "argocd", `${n.app}-data`);
        // ConfigMap(valkey-overrides)은 읽지 않는다. 데이터 Application의 source는 차트 태그(data-chart-v<버전>)라 revision은 main SHA가
        // 아니다(#883 r1 P2). main values는 ApplicationSet이 spec.source.helm.valuesObject로 넣으므로, 그 값과 Argo CD가 마지막으로
        // 비교한 값(status.sync.comparedTo)에 둘 다 running·restoreMode가 없고 Synced인지로 본다.
        const clean = (o: any) => o !== null && typeof o === "object" && o.valkey?.persistent === true && !("running" in o.valkey) && !("restoreMode" in o.valkey);
        const synced = !("running" in v) && !("restoreMode" in v) && argo?.status?.sync?.status === "Synced" && clean(argo?.spec?.source?.helm?.valuesObject) && clean(argo?.status?.sync?.comparedTo?.source?.helm?.valuesObject);
        return synced ? { state: "differs", action: "update", detail: "rollout restart → appendonly yes·키 수 확인" } : same("PR 병합 대기 또는 반영 대기", { hold: "Argo CD 반영 대기(복원 모드 끄기)" });
      },
      async apply(w) {
        // ok.aof는 그때의 서버 프로세스 이야기다. 복원 모드 끄기 PR을 기다리는 동안 서버가 재시작됐으면 ConfigMap이 아직
        // appendonly no라 AOF가 꺼진 채 RDB로 떠 있고, 디스크의 AOF는 그 전 것이다. 그대로 재시작하면 옛 AOF를 읽어 그사이
        // 쓰기를 잃는다(#883 Connector P1). 재시작 직전에 지금 서버를 보고, 꺼졌으면 표식을 지워 다음 실행이 AOF부터 다시 켜게 한다.
        const r = mine(w, n);
        if (has(r, "suspect.marker")) throw new Error(`앞 실행이 복원 표식 키가 없음을 봤다. 손으로 확인한다(restore.md 1절, --accept-empty로 넘길 수 없다)`);
        // 앞 실행이 0개를 봤으면 받아들이기 전에는 다시 재시작하지 않는다.
        if (has(r, "suspect.empty") && !acceptEmpty(w, n, acceptFlag)) suspectEmpty(w, n, "앞 실행이 키 0개를 봤다");
        const r0 = mine(w, n);
        const pre = appKeys(w, n, r0.run);
        // 재시작 전에 이미 없으면(복원 모드에서 재시작돼 RDB로 되돌아감) 재시작하지 않는다.
        if (!pre.marker) markerLost(w, n, "재시작 전에");
        if (pre.appendonly !== "yes" || !w.valkey.waitAof(n.ns, n.server, 60)) {
          mark(w, n, { "ok.aof": null });
          throw new Error(`지금 서버의 AOF가 켜져 있지 않거나 rewrite가 끝나지 않았다(appendonly ${pre.appendonly}, 그사이 재시작됐을 수 있다). 다시 실행하면 AOF부터 다시 켠다`);
        }
        // 첫 재시작 전 키 수를 기준으로 고정한다. 실패 뒤 재실행이 지금(이미 빈 서버)의 값을 기준으로 삼지 않게 한다.
        const base = r0.data["dbsize.pre"] !== undefined ? Number(r0.data["dbsize.pre"]) : pre.keys;
        if (!Number.isInteger(base) || base < 0) throw new Error("실행 기록의 dbsize.pre 형식이 아니다");
        if (r0.data["dbsize.pre"] === undefined) mark(w, n, { "dbsize.pre": String(pre.keys) });
        // 파드를 직접 지우지 않는다. Deployment 업데이트만 옛 파드가 끝난 뒤 새 파드를 띄운다(로컬 kind 실측 약 14초 겹침).
        w.k8s.rolloutRestart(n.ns, n.server);
        if (!w.k8s.rolloutStatus(n.ns, n.server, 300)) throw new Error("Valkey rollout이 끝나지 않았다");
        const s = appKeys(w, n, r0.run);
        if (s.appendonly !== "yes") throw new Error(`appendonly ${s.appendonly}다(복원 모드가 남아 있다)`);
        if (!s.marker) markerLost(w, n, "재시작 뒤");
        if (emptied([base, pre.keys], s.keys)) suspectEmpty(w, n, `재시작 뒤 키가 0개다(첫 재시작 전 ${base}개, 이번 재시작 직전 ${pre.keys}개). AOF에서 읽지 못했을 수 있다`);
        if (w.k8s.get("cronjob", n.ns, n.cronjob)?.spec?.suspend !== false) throw new Error(`CronJob ${n.cronjob}이 아직 suspend다`);
        mark(w, n, { "ok.reloaded": "1", "dbsize.after": String(s.keys) });
      },
    },
    {
      id: "cleanup",
      target: "이 실행의 Job",
      async read(ctx) {
        const r = record(ctx, n);
        if (has(r, "ok.cleanup")) return same("0개");
        if (!has(r, "ok.reloaded")) return later("지우고 0개 확인");
        return { state: "missing", action: "delete", detail: `복원 표식 키 지우고, 수동 백업·복원 Job 지우고 0개 확인` };
      },
      async apply(w) {
        const r = mine(w, n);
        const run = r.run;
        if (has(r, "marker")) {
          w.valkey.marker(n.ns, n.server, run, "del");
          mark(w, n, { marker: null });
        }
        w.k8s.deleteRestoreObjects(n.ns, run);
        const left = runObjects(w, n, r);
        if (left.length) throw new Error(`이 실행의 객체가 남았다(${left.join(", ")})`);
        mark(w, n, { "ok.cleanup": "1" });
      },
    },
  );
  return steps;
}

function finishSteps(n: Names): Step[] {
  return [
    {
      id: "done",
      target: "복원 결과",
      async read(ctx) {
        const r = record(ctx, n);
        if (!r) return same("기록 없음");
        if (!has(r, "ok.cleanup")) return { state: "differs", action: "none", detail: `실행 ${r.run}이 끝나지 않았다`, next: `homelab cache restore ${n.app} --apply로 끝까지 잇거나 --abort` };
        const left = runObjects(ctx, n, r);
        if (left.length) return { state: "differs", action: "none", detail: `실행 ${r.run}의 객체가 남아 있다(${left.join(", ")})`, next: `kubectl -n ${n.ns} get job,pod -l ${LABEL}=${r.run}로 보고 끝난 뒤 다시` };
        return same(`실행 ${r.run} 끝남(키 ${r.data["dbsize.after"] ?? r.data.dbsize}개)`);
      },
    },
    {
      id: "record-removed",
      target: `실행 기록 ${n.ns}/${RECORD}`,
      async read(ctx) {
        const r = record(ctx, n);
        return r ? { state: "differs", action: "delete", detail: `실행 ${r.run} 기록 지움` } : same("없음");
      },
      async apply(w) {
        const r = mine(w, n);
        // 기록이 잠금이다. 지우기 직전에 표식이 아니라 지금 클러스터를 다시 본다(#883 r1 P1-3).
        if (!has(r, "ok.cleanup")) throw new Error(`실행 ${r.run}이 끝나지 않았다`);
        const left = runObjects(w, n, r);
        if (left.length) throw new Error(`실행 ${r.run}의 객체가 남아 있다(${left.join(", ")}). 기록은 그대로다`);
        w.k8s.restoreRecordDelete(n.ns, RECORD, r.run);
      },
    },
  ];
}

// 복원 Job을 만들기 전에만 그만둘 수 있다. 그 뒤에는 PVC가 바뀌었을 수 있어 끝까지 잇는다.
function abortSteps(n: Names): Step[] {
  const app = n.app;
  return [
    {
      id: "abortable",
      target: "그만둘 수 있는지",
      async read(ctx) {
        const r = record(ctx, n);
        if (!r) {
          // 기록이 없으면 파괴 이전임을 기록으로 증명할 수 없다. 흔적이 하나라도 있으면 복원 설정을 지우는 PR을 열지 않는다(#883 r2 P1-1).
          const left = traces(ctx, n);
          if (left.length) return { state: "differs", action: "none", detail: `실행 기록 없이 복원 흔적이 있다(${left.join(", ")})`, next: `PVC가 바뀌었는지 손으로 확인한다(restore.md 1절, kubectl -n ${n.ns} get job,pod -L ${LABEL})` };
          return same("기록 없음, 복원 흔적 없음");
        }
        const next = `homelab cache restore ${app} --apply로 끝까지 잇는다`;
        // Job 유무가 아니라 Job을 만들기 전에 남긴 touched로 판단한다. Job은 지워질 수 있다(#883 r1 P1-1).
        if (has(r, "touched") || has(r, "ok.job")) return { state: "differs", action: "none", detail: "복원 Job을 만든 뒤라 PVC가 바뀌었을 수 있다", next };
        const users = [...(ctx.k8s.get("job", n.ns, JOB) ? [`job/${JOB}`] : []), ...restoreUsers(ctx, n)];
        if (users.length) return { state: "differs", action: "none", detail: `valkey-data를 쓰는 Job·파드가 있다(${users.join(", ")})`, next };
        return same(`실행 ${r.run}: 복원 Job 전`);
      },
    },
    holdPr(
      "pr-up",
      prStep({
        command: "cache restore abort",
        app,
        title: `cache restore ${app}: 그만두고 서버 올림`,
        body: `\`homelab cache restore ${app} --abort\`: 복원 Job 전에 그만둔다. \`running\`·\`restoreMode\` 줄을 지워 서버를 다시 올린다.`,
        files: [n.dataFile],
        edit: valkeyEdit(n, (v) => {
          delete v.running;
          delete v.restoreMode;
          return v;
        }),
      }),
    ),
    {
      id: "up",
      target: `서버 ${n.server}`,
      async read(ctx) {
        if (!record(ctx, n)) return same("기록 없음");
        const d = ctx.k8s.get("deployment", n.ns, n.server);
        if (!d) return same("PR 병합됨", { hold: "Argo CD 반영 대기(서버 Deployment 다시 생김)" });
        // 복원 전부터 장애였던 서버는 Ready가 안 될 수 있다. 그만두기를 Ready에 묶지 않고 알리기만 한다.
        return rolledOut(d) ? same("떠 있음") : same("Deployment 있음", { warn: "서버가 Ready가 아니다. 그만둔 뒤 따로 본다" });
      },
    },
    {
      id: "objects-removed",
      target: "이 실행의 Job·기록",
      async read(ctx) {
        return record(ctx, n) ? { state: "differs", action: "delete", detail: "수동 백업 Job과 실행 기록 지움" } : same("없음");
      },
      async apply(w) {
        const r = mine(w, n);
        // 지우기 직전에 다시 본다(abortable 뒤에 Job이 생겼을 수 있다).
        if (has(r, "touched") || has(r, "ok.job") || w.k8s.get("job", n.ns, JOB)) throw new Error("복원 Job을 만든 뒤라 그만두지 않는다");
        w.k8s.deleteRestoreObjects(n.ns, r.run);
        const left = runObjects(w, n, r);
        if (left.length) throw new Error(`이 실행의 객체가 남았다(${left.join(", ")}). 기록은 그대로다`);
        w.k8s.restoreRecordDelete(n.ns, RECORD, r.run);
      },
    },
  ];
}

export default defineCommand({
  path: ["cache", "restore"],
  summary: "영속 Valkey 복원(restore.md 1절). 끝나면 --finish",
  kind: "change",
  args: [{ name: "app", required: true, help: "앱 이름", pattern: APP_NAME }],
  flags: [
    { name: "object", kind: "value", valueName: "dump-<UTC>.rdb|latest", pattern: OBJECT, help: "R2 valkey/<app>/의 객체(기본 latest)" },
    { name: "backup-first", kind: "bool", help: "복원 전에 지금 상태를 수동 백업한다(0단계)" },
    { name: "accept-empty", kind: "bool", help: "앞 실행이 키 0개를 보고 멈춘 뒤, 비어 있는 것이 정상임을 확인했을 때만" },
    { name: "finish", kind: "bool", help: "끝난 복원의 실행 기록을 지운다" },
    { name: "abort", kind: "bool", help: "복원 Job 전이면 그만두고 서버를 다시 올린다" },
  ],
  async run(ctx, input) {
    const app = input.args.app as string;
    const finish = input.flags.finish === true;
    const abort = input.flags.abort === true;
    if (finish && abort) throw new UsageError("--finish와 --abort는 함께 쓰지 않는다");
    if ((finish || abort) && (input.flags.object !== undefined || input.flags["backup-first"] !== undefined || input.flags["accept-empty"] !== undefined)) throw new UsageError("--finish·--abort에는 --object·--backup-first·--accept-empty를 쓰지 않는다");
    const n: Names = { app, ns: `app-${app}`, server: `${app}-valkey`, cronjob: `${app}-valkey-backup`, dataFile: `data/${app}/values.yaml` };
    const object = (input.flags.object as string | undefined) ?? "latest";
    return ctx.engine({
      command: "cache restore",
      app,
      steps: finish ? finishSteps(n) : abort ? abortSteps(n) : mainSteps(n, object, input.flags["backup-first"] === true, input.flags["accept-empty"] === true),
      notes: finish ? [] : abort ? [`열린 PR(cli/cache-restore-${app}, cli/cache-restore-mode-${app})이 있으면 닫는다(병합하지 않는다).`] : ["서버를 내린 동안 앱은 Valkey 오류를 낸다. 복원하면 백업 시각 뒤에 쓴 키는 사라진다."],
      next: finish || abort ? undefined : (status) => (status === "done" || status === "same" ? `homelab cache restore ${app} --finish` : KEEP),
    });
  },
});
