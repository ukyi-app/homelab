// homelab olive ledger-init(장부 초기화 일회성 Job). 실제 클러스터에 닿지 않는다: kubectl은 PATH 스텁이다.
import { describe, expect, test } from "bun:test";
import type { Exec } from "../../src/core/exec";
import { kubectlArgv } from "../../src/core/kubectl";
import { oliveLedgerWrite } from "../../src/core/olive-ledger";
import { expectNoSecrets, expectPlanReadOnly, kubectlRule, rule, runCli, type Call, type Resp, type Rule } from "../harness";

const NS = "olive-control";
const JOB = "olive-ledger-init";
const JOB_UID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
const IMAGE = `ghcr.io/ukyi-app/olive@sha256:${"1".repeat(64)}`;
const CANARY = "canary-raw-output-5c1d";
const CTX = "test-cluster";
const OTHER_JOB_UID = "ffffffff-ffff-4fff-8fff-ffffffffffff";
const SUP_LABELS = { "app.kubernetes.io/name": "olive", "app.kubernetes.io/component": "supervisor", "app.kubernetes.io/part-of": "olive", "homelab.ukyi.app/olive-target": "supervisor" };
const INIT_LABELS = { "app.kubernetes.io/name": "olive", "app.kubernetes.io/component": "ledger-init", "app.kubernetes.io/part-of": "olive" };

const json = (x: unknown): Resp => ({ stdout: JSON.stringify(x) });
const notFound = (what: string): Resp => ({ code: 1, stderr: `Error from server (NotFound): ${what} not found\n` });
const list = (...items: unknown[]): Resp => json({ kind: "List", apiVersion: "v1", metadata: {}, items });

// 차트가 렌더하는 감독 Deployment에서 이 명령이 읽는 칸만(값은 platform/olive의 지금 값).
type Tweak = { image?: string; ledgerDir?: string; pvc?: string; limits?: { cpu: string; memory: string }; replicas?: number; observed?: number; liveReplicas?: number; podSc?: Record<string, unknown>; containerSc?: Record<string, unknown> };
function deployment(t: Tweak = {}) {
  const ledgerDir = t.ledgerDir ?? "/var/lib/olive";
  return {
    apiVersion: "apps/v1",
    kind: "Deployment",
    metadata: { name: "supervisor", namespace: NS, uid: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", generation: 3, labels: SUP_LABELS },
    spec: {
      replicas: t.replicas ?? 0,
      strategy: { type: "Recreate" },
      selector: { matchLabels: { "app.kubernetes.io/name": "olive", "app.kubernetes.io/component": "supervisor" } },
      template: {
        metadata: { labels: SUP_LABELS },
        spec: {
          serviceAccountName: "supervisor",
          automountServiceAccountToken: false,
          enableServiceLinks: false,
          securityContext: t.podSc ?? { runAsNonRoot: true, runAsUser: 65532, runAsGroup: 65532, fsGroup: 65532, seccompProfile: { type: "RuntimeDefault" } },
          containers: [
            {
              name: "supervisor",
              image: t.image ?? IMAGE,
              command: ["bun", "src/main/supervisor.ts"],
              env: [
                { name: "OLIVE_SUPERVISOR_PORT", value: "7443" },
                { name: "OLIVE_LEDGER_DIR", value: ledgerDir },
                { name: "OLIVE_RESULT_DIR", value: "/var/lib/olive-results" },
              ],
              securityContext: t.containerSc ?? { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: ["ALL"] } },
              resources: { requests: { cpu: "50m", memory: "128Mi" }, limits: t.limits ?? { cpu: "500m", memory: "768Mi" } },
              volumeMounts: [
                { name: "ledger", mountPath: ledgerDir },
                { name: "ledger", mountPath: "/var/lib/olive-results", subPath: "results" },
                { name: "signing", mountPath: "/run/olive/signing", readOnly: true },
                { name: "tmp", mountPath: "/tmp" },
              ],
            },
          ],
          volumes: [
            { name: "ledger", persistentVolumeClaim: { claimName: t.pvc ?? "ledger" } },
            { name: "signing", secret: { secretName: "olive-signing-key", defaultMode: 288 } },
            { name: "tmp", emptyDir: { sizeLimit: "256Mi" } },
          ],
        },
      },
    },
    status: { observedGeneration: t.observed ?? 3, ...(t.liveReplicas ? { replicas: t.liveReplicas } : {}) },
  };
}

// status.hard는 API 서버가 파드 생성을 심사하는 한도다(쿼터 컨트롤러가 spec.hard를 옮겨 적는다). enforced를 주면 그 값으로 바꾼다.
type QuotaTweak = { enforced?: { cpu: string; memory: string } | null; spec?: Record<string, unknown>; metadata?: Record<string, unknown> };
const quota = (hard = { cpu: "500m", memory: "768Mi" }, used: Record<string, string> | null = { "limits.cpu": "0", "limits.memory": "0" }, t: QuotaTweak = {}) => {
  const enforced = t.enforced === undefined ? hard : t.enforced;
  const status = { ...(enforced ? { hard: { "limits.cpu": enforced.cpu, "limits.memory": enforced.memory } } : {}), ...(used ? { used } : {}) };
  return json({ apiVersion: "v1", kind: "ResourceQuota", metadata: { name: "olive-limits", namespace: NS, ...t.metadata }, spec: { hard: { "limits.cpu": hard.cpu, "limits.memory": hard.memory }, ...t.spec }, ...(Object.keys(status).length ? { status } : {}) });
};
const pvc = (name = "ledger", extra: Record<string, unknown> = {}) => json({ apiVersion: "v1", kind: "PersistentVolumeClaim", metadata: { name, namespace: NS, ...extra }, status: { phase: "Bound" } });
const lock = (extra: Record<string, unknown> = {}) => json({ apiVersion: "v1", kind: "ResourceQuota", metadata: { name: "olive-stop", namespace: NS, labels: { "homelab.ukyi.app/olive-stop": "lock" }, ...extra }, spec: { hard: { pods: "0" } } });
const pod = (name: string, labels: Record<string, string>, extra: Record<string, unknown> = {}) => ({ apiVersion: "v1", kind: "Pod", metadata: { name, namespace: NS, uid: "dddddddd-dddd-4ddd-8ddd-dddddddddddd", labels }, spec: { volumes: [{ name: "ledger", persistentVolumeClaim: { claimName: "ledger" } }] }, status: { phase: "Running" }, ...extra });
const jobDoc = (conditions: unknown[] = []) => json({ apiVersion: "batch/v1", kind: "Job", metadata: { name: JOB, namespace: NS, uid: JOB_UID }, status: { conditions } });
const COMPLETE = [{ type: "Complete", status: "True" }];
const FAILED = [{ type: "Failed", status: "True", reason: "BackoffLimitExceeded" }];
const DEADLINE = [{ type: "Failed", status: "True", reason: "DeadlineExceeded" }];
// Job 컨트롤러가 만든 파드처럼 제어 참조가 그 Job(이름·UID)을 가리킨다. refs로 바꿔 다른 Job의 파드를 흉내 낸다.
const OWNED = [{ apiVersion: "batch/v1", kind: "Job", name: JOB, uid: JOB_UID, controller: true, blockOwnerDeletion: true }];
const initPod = (state: Record<string, unknown>, refs: unknown[] | null = OWNED) =>
  list({ apiVersion: "v1", kind: "Pod", metadata: { name: `${JOB}-x7k2p`, namespace: NS, labels: { ...INIT_LABELS, "batch.kubernetes.io/controller-uid": JOB_UID }, ...(refs ? { ownerReferences: refs } : {}) }, status: { phase: "Failed", containerStatuses: [{ name: "ledger-init", state }] } });
const exited = (exitCode: number, message?: string, reason = exitCode === 0 ? "Completed" : "Error", refs: unknown[] | null = OWNED) => initPod({ terminated: { exitCode, reason, ...(message ? { message } : {}) } }, refs);

// 실행 시작에 정한 문맥을 모든 kubectl 호출에 붙인다(current-context 한 번만 예외).
const PIN = `--context=${CTX}`;
const kube = (args: string[], resp: Resp | Resp[], ctx = CTX) => kubectlRule([`--context=${ctx}`, ...args], resp);
const createArgv = (ctx = CTX) => kubectlArgv([`--context=${ctx}`, "-n", NS, "create", "-f", "-", "-o", "json"]);
const deleteArgv = (ctx = CTX) => kubectlArgv([`--context=${ctx}`, "delete", "--raw", `/apis/batch/v1/namespaces/${NS}/jobs/${JOB}`, "-f", "-"]);
const CREATE = createArgv();
const DELETE = deleteArgv();
const CURRENT = ["kubectl", "config", "current-context"];

type World = {
  deploy?: Resp;
  pods?: Resp;
  stopLock?: Resp;
  quota?: Resp;
  pvc?: Resp;
  // 이름으로 읽는 Job: 확인(없어야 함) → 기다림 → 지운 뒤 확인 차례.
  jobs?: Resp[];
  initPods?: Resp | Resp[];
  create?: Resp;
  remove?: Resp;
  context?: Resp;
  // 현재 문맥 이름. current-context가 이 이름과 줄바꿈 하나를 내고, 뒤의 호출은 이 이름의 --context를 받아야 맞는다.
  ctx?: string;
};

function world(w: World = {}): Rule[] {
  const ctx = w.ctx ?? CTX;
  return [
    rule(CURRENT, w.context ?? { stdout: `${ctx}\n` }),
    kube(["-n", NS, "get", "deployments.apps", "supervisor", "-o", "json"], w.deploy ?? json(deployment()), ctx),
    kube(["-n", NS, "get", "pods", "-o", "json"], w.pods ?? list(), ctx),
    kube(["-n", NS, "get", "resourcequotas", "olive-stop", "-o", "json"], w.stopLock ?? notFound('resourcequotas "olive-stop"'), ctx),
    kube(["-n", NS, "get", "jobs.batch", JOB, "-o", "json"], w.jobs ?? [notFound(`jobs.batch "${JOB}"`), jobDoc(COMPLETE), notFound(`jobs.batch "${JOB}"`)], ctx),
    kube(["-n", NS, "get", "resourcequotas", "olive-limits", "-o", "json"], w.quota ?? quota(), ctx),
    kube(["-n", NS, "get", "persistentvolumeclaims", "ledger", "-o", "json"], w.pvc ?? pvc(), ctx),
    kube(["-n", NS, "get", "persistentvolumeclaims", "ledger-2", "-o", "json"], pvc("ledger-2"), ctx),
    kube(["-n", NS, "get", "pods", "-l", `batch.kubernetes.io/controller-uid=${JOB_UID}`, "-o", "json"], w.initPods ?? exited(0), ctx),
    rule(createArgv(ctx), w.create ?? json({ apiVersion: "batch/v1", kind: "Job", metadata: { name: JOB, namespace: NS, uid: JOB_UID } }), { captureStdin: true }),
    rule(deleteArgv(ctx), w.remove ?? json({ kind: "Status", status: "Success" }), { captureStdin: true }),
  ];
}

const argvs = (r: { calls: Call[] }, want: string[]) => r.calls.filter((c) => c.argv.join(" ") === want.join(" "));
const plan = (w: World = {}, extra: string[] = []) => runCli(["olive", "ledger-init", "--json", ...extra], world(w));
const apply = (w: World = {}, extra: string[] = []) => runCli(["olive", "ledger-init", "--apply", "--json", ...extra], world(w));

// 본보기(손으로 띄운 일회성 초기화 파드)와 같은 파드 모양. 이미지·장부 경로·PVC·보안 칸·자원은 라이브 감독 Deployment의 값이다.
const EXPECTED_JOB = {
  apiVersion: "batch/v1",
  kind: "Job",
  metadata: { name: JOB, namespace: NS, labels: INIT_LABELS },
  spec: {
    backoffLimit: 0,
    parallelism: 1,
    completions: 1,
    activeDeadlineSeconds: 300,
    ttlSecondsAfterFinished: 600,
    template: {
      metadata: { labels: INIT_LABELS },
      spec: {
        restartPolicy: "Never",
        serviceAccountName: "supervisor",
        automountServiceAccountToken: false,
        enableServiceLinks: false,
        securityContext: { runAsNonRoot: true, runAsUser: 65532, runAsGroup: 65532, fsGroup: 65532, seccompProfile: { type: "RuntimeDefault" } },
        containers: [
          {
            name: "ledger-init",
            image: IMAGE,
            command: ["bun", "src/main/ledger-init.ts"],
            env: [{ name: "OLIVE_LEDGER_DIR", value: "/var/lib/olive" }],
            securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: ["ALL"] } },
            resources: { limits: { cpu: "500m", memory: "768Mi" }, requests: { cpu: "50m", memory: "128Mi" } },
            terminationMessagePolicy: "FallbackToLogsOnError",
            volumeMounts: [
              { name: "ledger", mountPath: "/var/lib/olive" },
              { name: "tmp", mountPath: "/tmp" },
            ],
          },
        ],
        volumes: [
          { name: "ledger", persistentVolumeClaim: { claimName: "ledger" } },
          { name: "tmp", emptyDir: { sizeLimit: "256Mi" } },
        ],
      },
    },
  },
};

describe("plan", () => {
  test("plan은 읽기만 하고 대상·확인·Job 요약을 보인다", async () => {
    const r = await plan();
    expect(r.code).toBe(0);
    expectPlanReadOnly(r);
    expect(argvs(r, CREATE)).toEqual([]);
    expect(r.json.status).toBe("pending");
    expect(r.json.body.split("\n")).toEqual([
      "장부 초기화: --apply로 일회성 Job을 띄워 장부를 만든다",
      `대상: 문맥 test-cluster, ${NS}/supervisor`,
      "확인: 10개 모두 맞음",
      `Job: 이미지 ${IMAGE}, 장부 /var/lib/olive(PVC ledger), limits 500m·768Mi`,
    ]);
    expect(r.json.next).toBe("homelab olive ledger-init --apply");
  });

  test("--verbose는 확인마다 한 줄과 Job 자세히를 보인다", async () => {
    const r = await plan({}, ["--verbose"]);
    expect(r.code).toBe(0);
    const lines = r.json.body.split("\n");
    expect(lines.filter((l: string) => l.startsWith("확인: "))).toHaveLength(10);
    expect(lines).toContain(`Job ${NS}/${JOB}, 기한 300초, 끝난 뒤 600초면 스스로 지워짐`);
  });

  test("클러스터를 읽지 못하면 1이고 아무것도 만들지 않는다", async () => {
    const r = await plan({ deploy: { code: 1, stderr: `Error from server (Forbidden): ${CANARY}\n` } });
    expect(r.code).toBe(1);
    expect(r.json.error.message).toBe("장부 초기화: 클러스터를 읽지 못했다");
    expect(r.writes).toEqual([]);
    expect(`${r.stdout}${r.stderr}`.includes(CANARY)).toBe(false);
  });
});

describe("확인마다 거절(plan·--apply 모두 Job을 만들지 않는다)", () => {
  const supervisorPod = pod("supervisor-7c9d8f6b5-x2k4q", SUP_LABELS, { metadata: { name: "supervisor-7c9d8f6b5-x2k4q", namespace: NS, labels: SUP_LABELS, deletionTimestamp: "2026-11-28T06:00:00Z" } });
  // [이름, 세계, 종료 코드, 머리 줄의 어긋남, 다음 행동의 일부]
  const rows: [string, World, number, string, string][] = [
    ["감독 Deployment 없음", { deploy: notFound('deployments.apps "supervisor"') }, 1, "감독 Deployment가 없다", "차트를 먼저 적용"],
    ["replicas 1", { deploy: json(deployment({ replicas: 1 })) }, 1, "감독 replicas가 1이다", "감독을 끄고"],
    ["replicas 0 미반영", { deploy: json(deployment({ observed: 2 })) }, 3, "감독 Deployment가 replicas 0을 아직 반영하지 않았다", "잠시 뒤 다시"],
    ["status replicas 1", { deploy: json(deployment({ liveReplicas: 1 })) }, 3, "감독 파드 1개가 아직 Deployment에 남아 있다", "잠시 뒤 다시"],
    ["감독 파드 종료 중", { pods: list(supervisorPod) }, 3, "감독 파드가 1개 남아 있다(내려가는 중 포함)", "사라진 뒤 다시"],
    ["정지 자물쇠", { stopLock: lock() }, 1, "정지 자물쇠(olive-stop)가 걸려 있어 초기화 파드도 뜰 수 없다", "정지 절차대로 자물쇠를 푼 뒤"],
    ["정지 자물쇠 지우는 중", { stopLock: lock({ deletionTimestamp: "2026-11-28T06:00:00Z" }) }, 3, "정지 자물쇠(olive-stop)가 지워지는 중이다", "잠시 뒤 다시"],
    ["자물쇠 자리의 다른 쿼터", { stopLock: json({ apiVersion: "v1", kind: "ResourceQuota", metadata: { name: "olive-stop", namespace: NS }, spec: { hard: { pods: "5" } } }) }, 1, "정지 자물쇠 자리(olive-stop)에 다른 모양의 쿼터가 있다", "지우지 않는다"],
    ["지난 Job", { jobs: [jobDoc(COMPLETE)] }, 1, "지난 초기화 Job(olive-ledger-init)이 남아 있다", "600초면 스스로 지워진다"],
    ["지난 초기화 파드", { pods: list(pod(`${JOB}-old`, INIT_LABELS, { status: { phase: "Succeeded" } })) }, 1, "지난 초기화 파드가 남아 있다(1개)", "그 파드를 지운 뒤 다시"],
    ["장부를 붙인 다른 파드", { pods: list(pod("debug-shell", { app: "debug" })) }, 1, "장부 PVC를 붙인 다른 파드가 1개 있다", "그 파드가 끝난 뒤"],
    ["쿼터 사용량", { quota: quota(undefined, { "limits.cpu": "500m", "limits.memory": "768Mi" }) }, 3, "olive-limits 사용량이 0이 아니다", "잠시 뒤 다시"],
    ["쿼터 사용량 미계산", { quota: quota(undefined, null) }, 3, "olive-limits 사용량을 아직 계산하지 않았다", "잠시 뒤 다시"],
    ["쿼터 한도 ≠ 감독 limits", { quota: quota({ cpu: "1", memory: "768Mi" }) }, 1, "olive-limits 한도가 감독 limits와 다르다(감독과 함께 뜨는 것을 막지 못한다)", "olive-limits와 감독 resources"],
    ["쿼터 없음", { quota: notFound('resourcequotas "olive-limits"') }, 1, "olive-limits 쿼터가 없다(감독과 함께 뜨는 것을 막지 못한다)", "olive-limits를 확인"],
    ["태그 이미지", { deploy: json(deployment({ image: "ghcr.io/ukyi-app/olive:latest" })) }, 1, "감독 Deployment의 꼴이 예상과 다르다(image)", "CLI와 차트의 판"],
    ["컨테이너 보안 칸 추가", { deploy: json(deployment({ containerSc: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: ["ALL"] }, privileged: true } })) }, 1, "감독 Deployment의 꼴이 예상과 다르다(컨테이너 securityContext)", "CLI와 차트의 판"],
    ["파드 보안 칸 root", { deploy: json(deployment({ podSc: { runAsNonRoot: true, runAsUser: 0, runAsGroup: 65532, seccompProfile: { type: "RuntimeDefault" } } })) }, 1, "감독 Deployment의 꼴이 예상과 다르다(파드 securityContext)", "CLI와 차트의 판"],
    ["상대 장부 경로", { deploy: json(deployment({ ledgerDir: "var/lib/olive" })) }, 1, "감독 Deployment의 꼴이 예상과 다르다(OLIVE_LEDGER_DIR)", "CLI와 차트의 판"],
    ["장부 PVC 없음", { pvc: notFound('persistentvolumeclaims "ledger"') }, 1, "장부 PVC가 없다", "장부 PVC를 확인"],
    ["장부 PVC 지우는 중", { pvc: pvc("ledger", { deletionTimestamp: "2026-11-28T06:00:00Z" }) }, 1, "장부 PVC가 지워지는 중이다", "장부 PVC를 확인"],
  ];

  test("표의 각 줄: 종료 코드·머리 줄·다음 행동, create·delete 없음", async () => {
    for (const [name, w, code, line, next] of rows) {
      for (const mode of [[], ["--apply"]]) {
        const r = await runCli(["olive", "ledger-init", ...mode, "--json"], world(w));
        expect([name, mode, r.code]).toEqual([name, mode, code]);
        const head = r.json.body.split("\n")[0];
        expect([name, head]).toEqual([name, `장부 초기화: ${mode.length ? "Job을 만들지 않았다" : "만들 수 없다"}. ${line}`]);
        expect([name, String(r.json.next).includes(next)]).toEqual([name, true]);
        expect([name, r.writes.map((c) => c.argv)]).toEqual([name, []]);
        expect([name, r.unmatched.map((c) => c.argv)]).toEqual([name, []]);
      }
    }
  }, 240_000);

  test("어긋남이 여럿이면 하나라도 대기가 아니면 실패(1)이고 나머지를 줄로 보인다", async () => {
    const r = await plan({ deploy: json(deployment({ observed: 2 })), stopLock: lock() });
    expect(r.code).toBe(1);
    expect(r.json.body.split("\n")).toEqual([
      "장부 초기화: 만들 수 없다. 감독 Deployment가 replicas 0을 아직 반영하지 않았다",
      `대상: 문맥 test-cluster, ${NS}/supervisor`,
      "어긋남: 정지 자물쇠(olive-stop)가 걸려 있어 초기화 파드도 뜰 수 없다",
    ]);
  });
});

describe("Job 매니페스트", () => {
  test("본보기 파드와 같은 모양이고, 라벨에 감독 component·instance가 없고, Secret 볼륨·토큰이 없다", async () => {
    const r = await apply();
    expect(r.code).toBe(0);
    const created = argvs(r, CREATE);
    expect(created).toHaveLength(1);
    const job = JSON.parse(created[0]!.stdin ?? "");
    expect(job).toEqual(EXPECTED_JOB);
    for (const labels of [job.metadata.labels, job.spec.template.metadata.labels]) {
      expect(labels["app.kubernetes.io/component"]).toBe("ledger-init");
      expect(Object.keys(labels)).not.toContain("app.kubernetes.io/instance");
    }
    expect(JSON.stringify(job)).not.toMatch(/"secret"|"projected"|"Secret"/);
    expect(job.spec.template.spec.automountServiceAccountToken).toBe(false);
  });

  test("이미지·장부 경로·PVC·limits는 라이브 감독 Deployment의 값을 따른다", async () => {
    const image = `ghcr.io/ukyi-app/olive@sha256:${"2".repeat(64)}`;
    const limits = { cpu: "750m", memory: "1Gi" };
    const r = await apply({ deploy: json(deployment({ image, ledgerDir: "/var/lib/olive-ledger", pvc: "ledger-2", limits })), quota: quota(limits) });
    expect(r.code).toBe(0);
    const job = JSON.parse(argvs(r, CREATE)[0]!.stdin ?? "");
    const c = job.spec.template.spec.containers[0];
    expect([c.image, c.env, c.resources.limits, c.volumeMounts[0].mountPath, job.spec.template.spec.volumes[0].persistentVolumeClaim.claimName]).toEqual([image, [{ name: "OLIVE_LEDGER_DIR", value: "/var/lib/olive-ledger" }], limits, "/var/lib/olive-ledger", "ledger-2"]);
  });
});

describe("--apply 판정", () => {
  // [이름, Job 상태, 파드, 종료 코드, 머리 줄, 다음 행동]
  const rows: [string, unknown[], Resp, number, string, string | null][] = [
    ["0 만듦", COMPLETE, exited(0), 0, "장부 초기화: 장부를 만들었다", null],
    ["90 이미 있음", FAILED, exited(90, "olive ledger-init 0.1.0: 장부가 이미 있다. 아무것도 바꾸지 않았다\n"), 0, "장부 초기화: 장부가 이미 있다(바꾸지 않았다)", null],
    ["94 잠김", FAILED, exited(94, "olive ledger-init 0.1.0: 장부를 만들지 못했다(open:locked)\n"), 1, "장부 초기화 실패: 장부 열기가 실패했다(종료 94, open:locked). 장부가 만들어졌을 수 있다", "자동으로 다시 돌리지 않았다"],
    ["94 닫기 실패", FAILED, exited(94, "olive ledger-init 0.1.0: 장부를 만들지 못했다(close:threw)\n"), 1, "장부 초기화 실패: 장부는 만들었고 닫기가 실패했다(종료 94, close:threw)", "자동으로 다시 돌리지 않았다"],
    ["94 사유 꼴이 다름", FAILED, exited(94, `olive ledger-init 0.1.0: ${CANARY}\n`), 1, "장부 초기화 실패: 초기화 진입점이 종료 94로 끝났다(사유를 읽지 못함). 장부가 만들어졌을 수 있다", "자동으로 다시 돌리지 않았다"],
    ["91 환경", FAILED, exited(91, "olive ledger-init 0.1.0: 환경 OLIVE_LEDGER_DIR이(가) 없다\n"), 1, "장부 초기화 실패: 초기화 진입점이 장부 경로 환경을 받지 못했다(종료 91, env:missing)", "OLIVE_LEDGER_DIR을 확인"],
    ["64 사용법", FAILED, exited(64, "olive ledger-init 0.1.0: 사용법: bun src/main/ledger-init.ts (인자 없음)\n"), 1, "장부 초기화 실패: 초기화 진입점이 실행을 받지 않았다(종료 64, CLI와 감독 이미지의 판이 다를 수 있다)", "CLI와 차트의 판"],
    ["137 메모리 초과", FAILED, exited(137, undefined, "OOMKilled"), 1, "장부 초기화 실패: 초기화 파드가 종료 137로 끝났다(OOMKilled). 장부가 만들어졌을 수 있다", "다시 불러 확인한다"],
    ["기한 넘김", DEADLINE, list(), 1, "장부 초기화: 결과 모름. 초기화 파드가 기한 안에 끝나지 않았다. 장부가 만들어졌을 수 있다", "다시 불러 확인한다"],
    ["파드를 읽지 못함", FAILED, { code: 1, stderr: `Error from server (Forbidden): ${CANARY}\n` }, 1, "장부 초기화: 결과 모름. Job 실패는 확인했으나 초기화 파드의 종료 코드를 읽지 못했다. 장부가 만들어졌을 수 있다", "Job이 끝나고 지워진 뒤"],
    ["종료 코드 없음", FAILED, initPod({ waiting: { reason: "ContainerCreating" } }), 1, "장부 초기화: 결과 모름. 초기화 파드의 종료 코드를 읽지 못했다. 장부가 만들어졌을 수 있다", "다시 불러 확인한다"],
    ["상태와 코드가 어긋남", COMPLETE, exited(94, "olive ledger-init 0.1.0: 장부를 만들지 못했다(open:locked)\n"), 1, "장부 초기화: 결과 모름. Job 상태와 종료 코드가 맞지 않는다. 장부가 만들어졌을 수 있다", "다시 불러 확인한다"],
  ];

  test("표의 각 줄: 종료 코드·머리 줄·다음 행동, create는 한 번, 끝난 Job은 지운다, 원문 없음", async () => {
    for (const [name, conditions, pods, code, headline, next] of rows) {
      const after = name === "파드를 읽지 못함" ? [] : [notFound(`jobs.batch "${JOB}"`)];
      const r = await apply({ jobs: [notFound(`jobs.batch "${JOB}"`), jobDoc(conditions), ...after], initPods: pods });
      expect([name, r.code]).toEqual([name, code]);
      expect([name, r.json.body.split("\n")[0]]).toEqual([name, headline]);
      if (next === null) expect([name, r.json.next]).toEqual([name, null]);
      else expect([name, String(r.json.next).includes(next)]).toEqual([name, true]);
      if (code === 1) expect([name, r.json.error.message]).toEqual([name, headline]);
      expect([name, argvs(r, CREATE).length]).toEqual([name, 1]);
      expect([name, argvs(r, DELETE).length]).toEqual([name, name === "파드를 읽지 못함" ? 0 : 1]);
      expect([name, r.unmatched.map((c) => c.argv)]).toEqual([name, []]);
      expect([name, `${r.stdout}${r.stderr}`.includes(CANARY)]).toEqual([name, false]);
      expectNoSecrets(r);
    }
  }, 240_000);

  test("지우기는 만든 그 Job의 uid로만, 파드까지(Foreground)", async () => {
    const r = await apply();
    const body = JSON.parse(argvs(r, DELETE)[0]!.stdin ?? "");
    expect(body).toEqual({ kind: "DeleteOptions", apiVersion: "v1", propagationPolicy: "Foreground", preconditions: { uid: JOB_UID } });
  });

  test("끝나지 않으면 기다림 상한 뒤 결과 모름이고, 아직 쓰는 중일 수 있어 지우지 않는다", async () => {
    const r = await apply({ jobs: [notFound(`jobs.batch "${JOB}"`), jobDoc([])], initPods: initPod({ waiting: { reason: "ImagePullBackOff" } }) });
    expect(r.code).toBe(1);
    expect(r.json.body.split("\n")).toEqual([
      "장부 초기화: 결과 모름. 기다림 상한 안에 Job이 끝나지 않았다. 장부가 만들어졌을 수 있다",
      "Job olive-ledger-init을 지우지 않았다(아직 끝나지 않았다). 기한 300초에 끝나고, 끝난 뒤 600초면 스스로 지워진다",
      "마지막 파드 대기 사유 ImagePullBackOff",
    ]);
    expect(r.json.next).toBe("Job이 끝나고 지워진 뒤 다시 불러 확인한다: homelab olive ledger-init --apply(장부가 있으면 90으로 끝나고 바꾸지 않는다)");
    expect(argvs(r, DELETE)).toEqual([]);
  }, 30_000);

  test("지우기가 실패해도 판정은 그대로이고 ttl을 알린다", async () => {
    const r = await apply({ remove: { code: 1, stderr: `Error from server (Forbidden): ${CANARY}\n` } });
    expect(r.code).toBe(0);
    expect(r.json.body.split("\n")).toEqual(["장부 초기화: 장부를 만들었다", "Job olive-ledger-init을 지우지 못했다(exit 1). 끝난 뒤 600초면 스스로 지워진다"]);
    expect(`${r.stdout}${r.stderr}`.includes(CANARY)).toBe(false);
  });

  test("지운 뒤에도 Job이 남으면 지우지 못한 것으로 알린다", async () => {
    const r = await apply({ jobs: [notFound(`jobs.batch "${JOB}"`), jobDoc(COMPLETE)] });
    expect(r.code).toBe(0);
    expect(r.json.body.split("\n")[1]).toBe("Job olive-ledger-init을 지우지 못했다(still-there). 끝난 뒤 600초면 스스로 지워진다");
  }, 30_000);

  test("만들기가 시간 초과면 결과 모름이고 기다리거나 지우지 않는다", async () => {
    const r = await apply({ create: { sleepMs: 3_500 } });
    expect(r.code).toBe(1);
    expect(r.json.body.split("\n")).toEqual(["장부 초기화: 결과 모름. Job을 만들었는지 모른다(시간 초과). 장부가 만들어졌을 수 있다", "Job olive-ledger-init을 지우지 않았다(만들었는지 모른다). 있으면 끝난 뒤 600초면 스스로 지워진다"]);
    expect(argvs(r, CREATE)).toHaveLength(1);
    expect(argvs(r, DELETE)).toEqual([]);
  }, 30_000);

  test("끝난(쫓겨난) 감독 파드는 세지 않는다", async () => {
    const evicted = pod("supervisor-7c9d8f6b5-old", SUP_LABELS, { status: { phase: "Failed", reason: "Evicted" } });
    const r = await plan({ pods: list(evicted) });
    expect(r.code).toBe(0);
    expect(r.json.status).toBe("pending");
  });

  test("손으로 띄운 같은 이름의 초기화 파드가 남아 있으면 거절한다", async () => {
    const r = await plan({ pods: list(pod(JOB, { app: "x" }, { spec: {}, status: { phase: "Succeeded" } })) });
    expect(r.code).toBe(1);
    expect(r.json.body.split("\n")[0]).toBe("장부 초기화: 만들 수 없다. 지난 초기화 파드가 남아 있다(1개)");
  });

  test("만들기를 API가 거절하면 1이고 기다리거나 지우지 않는다", async () => {
    const r = await apply({ create: { code: 1, stderr: `Error from server (Forbidden): ${CANARY}\n` } });
    expect(r.code).toBe(1);
    expect(r.json.body).toBe("장부 초기화: Job을 만들지 못했다(API 서버가 거절했다). 아무것도 돌지 않았다");
    expect(argvs(r, DELETE)).toEqual([]);
  });

  test("--verbose는 Job 자세히·종료 코드·지움을 보이고, 기본은 한 줄이다", async () => {
    const short = await apply();
    expect(short.json.body).toBe("장부 초기화: 장부를 만들었다");
    const long = await apply({}, ["--verbose"]);
    expect(long.json.body.split("\n")).toEqual([
      "장부 초기화: 장부를 만들었다",
      `Job: 이미지 ${IMAGE}, 장부 /var/lib/olive(PVC ledger), limits 500m·768Mi`,
      `Job ${NS}/${JOB}, 기한 300초, 끝난 뒤 600초면 스스로 지워짐`,
      "Job을 지웠다",
      "파드 종료 코드 0",
    ]);
  });

  test("--json 문서와 사람용 출력", async () => {
    const r = await apply();
    expect([r.json.schema, r.json.command, r.json.mode, r.json.status, r.json.steps[0].result]).toEqual(["homelab-cli/v1", "olive ledger-init", "apply", "done", "applied"]);
    const human = await runCli(["olive", "ledger-init", "--apply"], world());
    expect(human.code).toBe(0);
    expect(`${human.stdout}${human.stderr}`).toContain("장부를 만들었다");
    expect(human.writes.map((c) => c.argv)).toEqual([CREATE, DELETE]);
  });
});

describe("사용법", () => {
  test("인자·모르는 플래그는 64이고 아무것도 부르지 않는다", async () => {
    for (const extra of [["now"], ["--force"], ["--verbose", "--verbose"], ["--wait=10"]]) {
      for (const mode of [[], ["--apply"]]) {
        const r = await runCli(["olive", "ledger-init", ...mode, ...extra, "--json"], world());
        expect([extra, mode, r.code]).toEqual([extra, mode, 64]);
        expect([extra, r.calls]).toEqual([extra, []]);
      }
    }
  }, 60_000);
});

describe("문맥 고정", () => {
  test("문맥을 한 번 정하고, 그 뒤의 kubectl 호출은 모두 같은 --context를 받는다(plan·--apply)", async () => {
    for (const r of [await plan(), await apply()]) {
      expect(r.unmatched.map((c) => c.argv)).toEqual([]);
      const kubectl = r.calls.filter((c) => c.argv[0] === "kubectl");
      expect(kubectl.filter((c) => c.argv.join(" ") === CURRENT.join(" "))).toHaveLength(1);
      expect(kubectl[0]!.argv).toEqual(CURRENT);
      expect(kubectl.slice(1).every((c) => c.argv[1] === PIN && c.argv.filter((a) => a.startsWith("--context")).length === 1)).toBe(true);
    }
    expect(argvs(await apply(), CREATE)).toHaveLength(1);
  });

  test("문맥을 정하지 못하면 다른 것을 읽거나 만들지 않고 1이다", async () => {
    for (const context of [{ code: 1, stderr: "error: current-context is not set\n" }, { stdout: "\n" }]) {
      for (const mode of [[], ["--apply"]]) {
        const r = await runCli(["olive", "ledger-init", ...mode, "--json"], world({ context }));
        expect([mode, r.code]).toEqual([mode, 1]);
        expect([mode, r.json.body.split("\n")[0]]).toEqual([mode, `장부 초기화: ${mode.length ? "Job을 만들지 않았다" : "만들 수 없다"}. kubectl 문맥을 정하지 못했다`]);
        expect([mode, r.calls.map((c) => c.argv)]).toEqual([mode, [CURRENT]]);
        expect([mode, r.writes]).toEqual([mode, []]);
      }
    }
  });
});

describe("집행 중인 쿼터", () => {
  const rows: [string, Resp, number, string][] = [
    ["status.hard가 감독 limits보다 큼", quota(undefined, undefined, { enforced: { cpu: "1", memory: "1536Mi" } }), 3, "olive-limits가 집행 중인 한도(status.hard)가 아직 감독 limits와 같지 않다"],
    ["status.hard 없음", quota(undefined, undefined, { enforced: null }), 3, "olive-limits가 집행 중인 한도(status.hard)가 아직 감독 limits와 같지 않다"],
    ["적용 범위 scopes", quota(undefined, undefined, { spec: { scopes: ["Terminating"] } }), 1, "olive-limits에 적용 범위(scopes·scopeSelector)가 있다(차트와 다르다)"],
    ["적용 범위 scopeSelector", quota(undefined, undefined, { spec: { scopeSelector: { matchExpressions: [{ scopeName: "PriorityClass", operator: "In", values: ["high"] }] } } }), 1, "olive-limits에 적용 범위(scopes·scopeSelector)가 있다(차트와 다르다)"],
    ["쿼터 지우는 중", quota(undefined, undefined, { metadata: { deletionTimestamp: "2026-11-28T05:00:00Z" } }), 1, "olive-limits 쿼터가 지워지는 중이다(감독과 함께 뜨는 것을 막지 못한다)"],
  ];
  test("표의 각 줄: plan·--apply 모두 Job을 만들지 않는다", async () => {
    for (const [name, q, code, line] of rows) {
      for (const mode of [[], ["--apply"]]) {
        const r = await runCli(["olive", "ledger-init", ...mode, "--json"], world({ quota: q }));
        expect([name, mode, r.code]).toEqual([name, mode, code]);
        expect([name, r.json.body.split("\n")[0]]).toEqual([name, `장부 초기화: ${mode.length ? "Job을 만들지 않았다" : "만들 수 없다"}. ${line}`]);
        expect([name, argvs(r, CREATE).length, r.writes.length]).toEqual([name, 0, 0]);
        expect([name, r.unmatched.map((c) => c.argv)]).toEqual([name, []]);
      }
    }
  }, 60_000);
});

describe("만들기 응답을 잃음", () => {
  const lost: [string, Resp][] = [
    ["응답 기한", { code: 1, stderr: "error: Post \"https://example.invalid/apis/batch/v1/namespaces/olive-control/jobs\": context deadline exceeded\n" }],
    ["연결 끊김", { code: 1, stderr: "error: Post \"https://example.invalid/apis/batch/v1/namespaces/olive-control/jobs\": read tcp: connection reset by peer\n" }],
    ["EOF", { code: 1, stderr: "error: Post \"https://example.invalid/apis/batch/v1/namespaces/olive-control/jobs\": unexpected EOF\n" }],
    ["다른 Job의 Invalid 꼴", { code: 1, stderr: "The Job \"other-job\" is invalid: spec.template: Invalid value\n" }],
    ["줄 가운데의 거절 꼴", { code: 1, stderr: "error: Post: EOF (The request is invalid: x)\n" }],
    ["서버 응답 기한", { code: 1, stderr: "Error from server (Timeout): the server was unable to return a response in the time allotted\n" }],
    ["서버 내부 오류", { code: 1, stderr: "Error from server (InternalError): Internal error occurred\n" }],
    // 최상위 오류가 거절이 아니면 뒤 줄(서버가 붙인 세부)에 거절 꼴이 있어도 결과 모름이다.
    ["서버 내부 오류 뒤 줄의 Invalid 꼴", { code: 1, stderr: 'Error from server (InternalError): error when creating "STDIN": Internal error occurred:\nThe request is invalid: validation service unavailable\n' }],
    ["서버 응답 기한 뒤 줄의 Invalid 꼴", { code: 1, stderr: `Error from server (Timeout): request did not complete within requested timeout\nThe Job "${JOB}" is invalid: cached validation detail\n` }],
    ["연결 오류 뒤 줄의 Unauthorized 꼴", { code: 1, stderr: 'error: Post "https://example.invalid/apis/batch/v1/namespaces/olive-control/jobs": unexpected EOF\nerror: You must be logged in to the server (Unauthorized)\n' }],
    ["서버 내부 오류 뒤 줄의 Forbidden 꼴", { code: 1, stderr: "Error from server (InternalError): Internal error occurred\nError from server (Forbidden): jobs.batch is forbidden\n" }],
  ];
  test("명확한 거절이 아닌 실패는 결과 모름(1)이고 기다리거나 지우지 않는다", async () => {
    for (const [name, create] of lost) {
      const r = await apply({ create });
      expect([name, r.code]).toEqual([name, 1]);
      expect([name, r.json.body.split("\n")]).toEqual([name, ["장부 초기화: 결과 모름. Job을 만들었는지 모른다(만들기 응답을 받지 못했다). 장부가 만들어졌을 수 있다", "Job olive-ledger-init을 지우지 않았다(만들었는지 모른다). 있으면 끝난 뒤 600초면 스스로 지워진다"]]);
      expect([name, argvs(r, CREATE).length, argvs(r, DELETE).length]).toEqual([name, 1, 0]);
      expect([name, r.calls.filter((c) => c.argv.includes(`batch.kubernetes.io/controller-uid=${JOB_UID}`)).length]).toEqual([name, 0]);
    }
  }, 60_000);

  // kubectl 1.36.6이 거절을 내는 꼴(cmd/util/helpers.go의 checkErr·StandardErrorMessage). Invalid와 Unauthorized는
  // "Error from server (이유)" 꼴로 나오지 않는다.
  const refusals: [string, string][] = [
    ["BadRequest", `Error from server (BadRequest): ${CANARY}\n`],
    ["NotFound", `Error from server (NotFound): ${CANARY}\n`],
    ["Forbidden", `Error from server (Forbidden): error when creating "STDIN": jobs.batch is forbidden: ${CANARY}\n`],
    ["Invalid 원인 하나", `The Job "${JOB}" is invalid: spec.template.spec.containers[0].image: Required value: ${CANARY}\n`],
    ["Invalid 원인 여럿", `The Job "${JOB}" is invalid: \n* spec.template: Invalid value: ${CANARY}\n* spec.completions: Invalid value: 2\n`],
    ["Invalid 원인 없음", "The Job \"olive-ledger-init\" is invalid\n"],
    ["Invalid 세부 없음", `The request is invalid: ${CANARY}\n`],
    ["Unauthorized", `error: You must be logged in to the server (error when creating "STDIN": Unauthorized)\n`],
    ["Unauthorized 자격 요구", "error: You must be logged in to the server (the server has asked for the client to provide credentials)\n"],
  ];
  test("API의 명확한 거절은 만들지 않음이다", async () => {
    for (const [word, stderr] of refusals) {
      const r = await apply({ create: { code: 1, stderr } });
      expect([word, r.code, r.json.body]).toEqual([word, 1, "장부 초기화: Job을 만들지 못했다(API 서버가 거절했다). 아무것도 돌지 않았다"]);
      expect([word, argvs(r, DELETE).length]).toEqual([word, 0]);
      expect([word, `${r.stdout}${r.stderr}`.includes(CANARY)]).toEqual([word, false]);
    }
    const exists = await apply({ create: { code: 1, stderr: `Error from server (AlreadyExists): ${CANARY}\n` } });
    expect(exists.json.body).toBe("장부 초기화: Job을 만들지 못했다(같은 이름의 Job이 먼저 생겼다). 아무것도 돌지 않았다");
  }, 60_000);
});

describe("종료 코드를 낸 파드의 신원", () => {
  const other = [{ apiVersion: "batch/v1", kind: "Job", name: "other-job", uid: OTHER_JOB_UID, controller: true }];
  const rows: [string, unknown[] | null][] = [
    ["다른 Job의 파드", other],
    ["제어 참조 없음", null],
    ["controller가 아님", [{ ...OWNED[0], controller: false }]],
    ["같은 이름 다른 UID", [{ ...OWNED[0], uid: OTHER_JOB_UID }]],
    ["다른 종류", [{ ...OWNED[0], kind: "CronJob" }]],
    ["다른 apiVersion", [{ ...OWNED[0], apiVersion: "batch/v1beta1" }]],
    ["제어 참조 둘", [...OWNED, ...other]],
  ];
  test("만든 Job이 제어하는 파드임을 입증하지 못하면 결과 모름이다", async () => {
    for (const [name, refs] of rows) {
      const r = await apply({ jobs: [notFound(`jobs.batch "${JOB}"`), jobDoc(FAILED), notFound(`jobs.batch "${JOB}"`)], initPods: exited(90, "olive ledger-init 0.1.0: 장부가 이미 있다. 아무것도 바꾸지 않았다\n", "Error", refs) });
      expect([name, r.code]).toEqual([name, 1]);
      expect([name, r.json.body.split("\n")[0]]).toEqual([name, "장부 초기화: 결과 모름. 종료 코드를 낸 파드가 만든 Job의 것인지 확인하지 못했다. 장부가 만들어졌을 수 있다"]);
    }
  }, 60_000);
});

describe("사유는 알려진 값만", () => {
  test("진입점 목록 밖의 낱말은 내지 않는다", async () => {
    const r = await apply({ jobs: [notFound(`jobs.batch "${JOB}"`), jobDoc(FAILED), notFound(`jobs.batch "${JOB}"`)], initPods: exited(94, "olive ledger-init 0.1.0: 장부를 만들지 못했다(open:review_marker)\n") });
    expect(r.code).toBe(1);
    expect(r.json.body.split("\n")[0]).toBe("장부 초기화 실패: 초기화 진입점이 종료 94로 끝났다(사유를 읽지 못함). 장부가 만들어졌을 수 있다");
    expect(`${r.stdout}${r.stderr}`.includes("review_marker")).toBe(false);
  });

  test("Kubernetes 사유도 목록 밖이면 내지 않는다(종료·대기)", async () => {
    const term = await apply({ jobs: [notFound(`jobs.batch "${JOB}"`), jobDoc(FAILED), notFound(`jobs.batch "${JOB}"`)], initPods: exited(137, undefined, "ReviewMarker") }, ["--verbose"]);
    expect(term.json.body.split("\n")[0]).toBe("장부 초기화 실패: 초기화 파드가 종료 137로 끝났다(사유를 읽지 못함). 장부가 만들어졌을 수 있다");
    expect(`${term.stdout}${term.stderr}`.includes("ReviewMarker")).toBe(false);
    const wait = await apply({ jobs: [notFound(`jobs.batch "${JOB}"`), jobDoc([])], initPods: initPod({ waiting: { reason: "ReviewMarker" } }) });
    expect(wait.json.body.split("\n")).toEqual([
      "장부 초기화: 결과 모름. 기다림 상한 안에 Job이 끝나지 않았다. 장부가 만들어졌을 수 있다",
      "Job olive-ledger-init을 지우지 않았다(아직 끝나지 않았다). 기한 300초에 끝나고, 끝난 뒤 600초면 스스로 지워진다",
    ]);
  }, 30_000);
});

describe("종료 94의 안내", () => {
  // 진입점이 내는 94 사유 16개(olive src/main/ledger-init.ts의 failed 호출과 src/ledger/errors.ts의 UNAVAILABLE_REASONS에서
  // already_initialized를 뺀 것). before: 첫 설치 기록을 커밋하기 전에만 나는 판정, maybe: 커밋 뒤(WAL 전환·장부 객체 생성)에도
  // SQLite 오류의 분류로 날 수 있는 사유, made: 만든 뒤의 닫기 실패.
  const kinds: [string, "before" | "maybe" | "made"][] = [
    ["deps:threw", "before"],
    ["open:too_new", "before"],
    ["open:migration_mismatch", "before"],
    ["open:migration_failed", "before"],
    ["open:not_initialized", "before"],
    ["open:foreign_data", "before"],
    ["open:interrupted_install", "before"],
    ["open:locked", "maybe"],
    ["open:corrupt", "maybe"],
    ["open:full", "maybe"],
    ["open:io", "maybe"],
    ["open:closed", "maybe"],
    ["open:db_error", "maybe"],
    ["open:threw", "maybe"],
    ["open:unreadable", "maybe"],
    ["close:threw", "made"],
  ];
  const failedWorld = (message?: string): World => ({ jobs: [notFound(`jobs.batch "${JOB}"`), jobDoc(FAILED), notFound(`jobs.batch "${JOB}"`)], initPods: exited(94, message) });
  const both = (text: string) => text.includes("만들지 못했다") && text.includes("만들어졌을 수 있다");

  test("사유 16개마다 장부가 생겼는지를 한 가지로 말하고, 1이며 다시 돌리지 않는다", async () => {
    expect(kinds).toHaveLength(16);
    for (const [reason, kind] of kinds) {
      const r = await apply(failedWorld(`olive ledger-init 0.1.0: 장부를 만들지 못했다(${reason})\n`));
      const headline =
        kind === "before" ? `장부 초기화 실패: 장부를 만들지 못했다(종료 94, ${reason})` : kind === "maybe" ? `장부 초기화 실패: 장부 열기가 실패했다(종료 94, ${reason}). 장부가 만들어졌을 수 있다` : "장부 초기화 실패: 장부는 만들었고 닫기가 실패했다(종료 94, close:threw)";
      expect([reason, r.code, r.json.body.split("\n")[0], r.json.error.message]).toEqual([reason, 1, headline, headline]);
      const next = String(r.json.next);
      expect([reason, next.includes("자동으로 다시 돌리지 않았다")]).toEqual([reason, true]);
      expect([reason, next.includes(kind === "before" ? "장부 자리를 바로잡은 뒤 다시: homelab olive ledger-init(" : "다시 불러 확인한다: homelab olive ledger-init --apply")]).toEqual([reason, true]);
      expect([reason, both(r.json.body), both(r.json.error.message)]).toEqual([reason, false, false]);
      // 만든 뒤의 닫기 실패는 본문 어디에도 만들지 못했다·만들어졌을 수 있다를 싣지 않는다(한 줄만 덧붙어도 모순이다).
      if (kind === "made") {
        for (const text of [r.json.body, r.json.error.message]) {
          expect([reason, text.includes("만들지 못했다"), text.includes("만들어졌을 수 있다")]).toEqual([reason, false, false]);
        }
      }
      expect([reason, argvs(r, CREATE).length]).toEqual([reason, 1]);
    }
  }, 120_000);

  test("사유를 읽지 못한 94와 시점을 가릴 수 없는 사유는 사람용·JSON 모두 만들어졌을 수 있다고만 말한다", async () => {
    for (const message of [undefined, "olive ledger-init 0.1.0: 장부를 만들지 못했다(open:corrupt)\n"]) {
      const machine = await apply(failedWorld(message));
      expect([message, machine.code, both(machine.json.body), both(machine.json.error.message), machine.json.body.includes("만들어졌을 수 있다")]).toEqual([message, 1, false, false, true]);
      const human = await runCli(["olive", "ledger-init", "--apply"], world(failedWorld(message)));
      expect([message, human.code, both(`${human.stdout}${human.stderr}`), `${human.stdout}${human.stderr}`.includes("만들어졌을 수 있다")]).toEqual([message, 1, false, true]);
    }
  }, 60_000);
});

describe("문맥 이름", () => {
  const shown: [string, string][] = [
    [" test-cluster ", '" test-cluster "'],
    ["홈랩", "홈랩"],
    ["test cluster", '"test cluster"'],
    ["it's $(touch x) `id`", "\"it's $(touch x) `id`\""],
  ];
  test("이름을 줄바꿈 하나만 떼고 그대로 쓴다: 한글·공백·셸 문자도 plan·--apply가 그 이름의 --context로만 간다", async () => {
    for (const [ctx, label] of shown) {
      const pin = `--context=${ctx}`;
      const p = await plan({ ctx });
      expect([ctx, p.code, p.json.status, p.unmatched.map((c) => c.argv)]).toEqual([ctx, 0, "pending", []]);
      expect([ctx, p.json.body.split("\n")[1]]).toEqual([ctx, `대상: 문맥 ${label}, ${NS}/supervisor`]);
      expectPlanReadOnly(p);
      const a = await apply({ ctx });
      expect([ctx, a.code, a.json.body, a.unmatched.map((c) => c.argv)]).toEqual([ctx, 0, "장부 초기화: 장부를 만들었다", []]);
      expect([ctx, argvs(a, createArgv(ctx)).length, argvs(a, deleteArgv(ctx)).length]).toEqual([ctx, 1, 1]);
      for (const r of [p, a]) {
        const kubectl = r.calls.filter((c) => c.argv[0] === "kubectl");
        expect([ctx, kubectl[0]!.argv]).toEqual([ctx, CURRENT]);
        expect([ctx, kubectl.slice(1).every((c) => c.argv[1] === pin && c.argv.filter((x) => x.startsWith("--context")).length === 1)]).toEqual([ctx, true]);
        expect([ctx, r.calls.some((c) => c.argv.includes(PIN))]).toEqual([ctx, ctx === CTX]);
      }
    }
  }, 120_000);

  test("따옴표·역슬래시·보이지 않는 글자가 든 이름은 인용·이스케이프해 서로 다른 이름이 같은 대상 줄로 보이지 않는다", async () => {
    const names: [string, string][] = [
      ["ctx", "ctx"],
      ["ctx\u200b", '"ctx\\u{200b}"'],
      ['"ctx\\u{200b}"', '"\\"ctx\\\\u{200b}\\""'],
      ["ctx\u034f", '"ctx\\u{34f}"'],
      ['a"b', '"a\\"b"'],
      ["a\\b", '"a\\\\b"'],
      ["a\u00a0b", '"a\\u{a0}b"'],
    ];
    const targets: string[] = [];
    for (const [ctx, label] of names) {
      const p = await plan({ ctx });
      expect([ctx, p.code, p.unmatched.map((c) => c.argv)]).toEqual([ctx, 0, []]);
      const line = p.json.body.split("\n")[1];
      expect([ctx, line]).toEqual([ctx, `대상: 문맥 ${label}, ${NS}/supervisor`]);
      targets.push(line);
    }
    expect(new Set(targets).size).toBe(names.length);
  }, 60_000);

  test("제어 문자·빈 이름·끝 줄바꿈이 없는 출력이면 다른 것을 읽거나 만들지 않고 1이다", async () => {
    for (const stdout of ["a\tb\n", "a\u001b[2Jb\n", `${CTX}\r\n`, `${CTX}\n\n`, CTX, "a\u0085b\n", "a\ufffdb\n", "\n", ""]) {
      for (const mode of [[], ["--apply"]]) {
        const r = await runCli(["olive", "ledger-init", ...mode, "--json"], world({ context: { stdout } }));
        expect([stdout, mode, r.code]).toEqual([stdout, mode, 1]);
        expect([stdout, mode, r.json.body.split("\n")[0]]).toEqual([stdout, mode, `장부 초기화: ${mode.length ? "Job을 만들지 않았다" : "만들 수 없다"}. kubectl 문맥을 정하지 못했다`]);
        expect([stdout, mode, r.calls.map((c) => c.argv), r.writes]).toEqual([stdout, mode, [CURRENT], []]);
      }
    }
  }, 120_000);
});

describe("한도 0", () => {
  const rows: { cpu: string; memory: string }[] = [
    { cpu: "0", memory: "768Mi" },
    { cpu: "500m", memory: "0" },
    { cpu: "0m", memory: "0Mi" },
    { cpu: "0.000", memory: "0Gi" },
  ];
  test("감독 limits의 CPU나 메모리가 0이면 쿼터가 같아도 plan·--apply 모두 실패(1)이고 만들지 않는다", async () => {
    for (const limits of rows) {
      for (const mode of [[], ["--apply"]]) {
        const r = await runCli(["olive", "ledger-init", ...mode, "--json"], world({ deploy: json(deployment({ limits })), quota: quota(limits) }));
        expect([limits, mode, r.code]).toEqual([limits, mode, 1]);
        expect([limits, mode, r.json.body.split("\n")[0]]).toEqual([limits, mode, `장부 초기화: ${mode.length ? "Job을 만들지 않았다" : "만들 수 없다"}. 감독 limits에 0인 자원이 있다(초기화는 CPU와 메모리 둘 다 양수 한도를 요구한다)`]);
        expect([limits, mode, argvs(r, CREATE).length, r.writes.length]).toEqual([limits, mode, 0, 0]);
      }
    }
  }, 60_000);

  test("Job 모양을 거절해도 쿼터 한도는 감독 limits와 비교하고, 비교하지 못하면 확인으로 보이지 않는다", async () => {
    const ok = "확인: olive-limits 사용량 0, 집행 중인 한도 = 감독 limits, 적용 범위 없음";
    const rows: [string, World, string | null][] = [
      ["한도 0, 쿼터가 다름", { deploy: json(deployment({ limits: { cpu: "0", memory: "768Mi" } })), quota: quota({ cpu: "500m", memory: "768Mi" }) }, "어긋남: olive-limits 한도가 감독 limits와 다르다(감독과 함께 뜨는 것을 막지 못한다)"],
      ["한도 0, 쿼터가 같음", { deploy: json(deployment({ limits: { cpu: "0", memory: "768Mi" } })), quota: quota({ cpu: "0", memory: "768Mi" }) }, null],
      ["limits를 읽지 못함", { deploy: json(deployment({ limits: { cpu: "500m" } as { cpu: string; memory: string } })) }, "어긋남: olive-limits 한도를 감독 limits와 비교하지 못했다(감독 limits를 읽지 못했다)"],
      ["감독 Deployment 없음", { deploy: notFound('deployments.apps "supervisor"') }, "어긋남: olive-limits 한도를 감독 limits와 비교하지 못했다(감독 limits를 읽지 못했다)"],
    ];
    for (const [name, w, line] of rows) {
      for (const mode of [[], ["--apply"]]) {
        const r = await runCli(["olive", "ledger-init", ...mode, "--json", "--verbose"], world(w));
        const lines: string[] = r.json.body.split("\n");
        expect([name, mode, r.code, argvs(r, CREATE).length, r.writes.length]).toEqual([name, mode, 1, 0, 0]);
        expect([name, mode, lines.includes(ok)]).toEqual([name, mode, line === null]);
        if (line !== null) expect([name, mode, lines.includes(line)]).toEqual([name, mode, true]);
      }
    }
  }, 60_000);

  test("0이 아닌 작은 한도는 지금처럼 계획한다", async () => {
    const limits = { cpu: "1m", memory: "1Ki" };
    const r = await plan({ deploy: json(deployment({ limits })), quota: quota(limits) });
    expect([r.code, r.json.status]).toEqual([0, "pending"]);
  });
});

describe("기다림 상한", () => {
  // 스텁 대신 가짜 exec로 조회마다 지연을 넣고, 각 조회가 받은 실행 제한을 적는다.
  function fake(delayMs: number, w: World = {}) {
    const rules = world(w);
    const asked: { argv: string[]; timeoutMs: number | undefined }[] = [];
    let created = false;
    const exec = (argv: string[], opts: { timeoutMs?: number } = {}) => {
      const row = rules.find((r) => JSON.stringify(r.argv) === JSON.stringify(argv));
      if (!row) throw new Error(`가짜 응답이 없는 호출: ${argv.join(" ")}`);
      if (argv.includes("create")) created = true;
      else if (created && argv.includes("get")) {
        asked.push({ argv, timeoutMs: opts.timeoutMs });
        Bun.sleepSync(delayMs);
      }
      const r = (row.responses.length > 1 ? row.responses.shift() : row.responses[0]) as Resp;
      return { code: r.code ?? 0, stdout: r.stdout ?? "", stderr: r.stderr ?? "", notFound: r.stderr?.includes("(NotFound)") ?? false };
    };
    return { exec, asked };
  }

  test("조회마다 남은 시간을 실행 제한으로 넘기고, 상한이 지난 관측은 결과 모름이다", () => {
    const { exec, asked } = fake(35);
    const out = oliveLedgerWrite(exec, exec, { capMs: 50, pollMs: 2 }).run();
    expect(out.state).toBe("unknown");
    expect(out.state === "unknown" ? out.why : null).toBe("wait");
    const watch = asked.filter((a) => a.argv.includes("jobs.batch") || a.argv.includes("-l")).slice(0, 2);
    expect(watch).toHaveLength(2);
    for (const a of watch) expect(typeof a.timeoutMs === "number" && a.timeoutMs >= 1 && a.timeoutMs <= 50).toBe(true);
    expect((watch[1]!.timeoutMs as number) < (watch[0]!.timeoutMs as number)).toBe(true);
  });

  test("상한 안의 관측은 지금처럼 판정한다", () => {
    const { exec } = fake(0);
    expect(oliveLedgerWrite(exec, exec, { capMs: 5_000, pollMs: 2 }).run().state).toBe("created");
  });

  test("끝난 Job의 첫 파드 조회가 상한에 끊기면 아직 끝나지 않았다가 아니라 읽지 못함(결과 모름)이다", () => {
    const { exec } = fake(0);
    const slow: Exec = (argv, opts) => {
      if (!argv.includes("-l")) return exec(argv, opts);
      Bun.sleepSync(80);
      return { code: null, stdout: "", stderr: "", notFound: false, errKind: "timeout" };
    };
    const out = oliveLedgerWrite(slow, slow, { capMs: 50, pollMs: 2 }).run();
    expect(out).toMatchObject({ state: "unknown", why: "complete-unread", cleanup: { state: "kept", why: "exit-unread" } });
  });

  test("실행 중을 읽은 뒤 같은 UID의 완료를 읽고 파드 조회가 상한에 끊기면 아직 끝나지 않았다가 아니라 완료·종료 코드 못 읽음이다", () => {
    const { exec } = fake(0, { jobs: [notFound(`jobs.batch "${JOB}"`), jobDoc([]), jobDoc(COMPLETE)], initPods: initPod({ running: {} }) });
    let lists = 0;
    const slow: Exec = (argv, opts) => {
      if (!argv.includes("-l") || ++lists === 1) return exec(argv, opts);
      Bun.sleepSync(80);
      return { code: null, stdout: "", stderr: "", notFound: false, errKind: "timeout" };
    };
    const out = oliveLedgerWrite(slow, slow, { capMs: 50, pollMs: 2 }).run();
    expect(lists).toBe(2);
    expect(out).toMatchObject({ state: "unknown", why: "complete-unread", cleanup: { state: "kept", why: "exit-unread" } });
  });

  test("실패를 읽은 뒤 파드 조회가 끊기면 실패는 확인했으나 종료 코드를 읽지 못함이다", () => {
    const { exec } = fake(0, { jobs: [notFound(`jobs.batch "${JOB}"`), jobDoc(FAILED)] });
    const slow: Exec = (argv, opts) => {
      if (!argv.includes("-l")) return exec(argv, opts);
      Bun.sleepSync(80);
      return { code: null, stdout: "", stderr: "", notFound: false, errKind: "timeout" };
    };
    const out = oliveLedgerWrite(slow, slow, { capMs: 50, pollMs: 2 }).run();
    expect(out).toMatchObject({ state: "unknown", why: "failed-unread", cleanup: { state: "kept", why: "exit-unread" } });
  });
});

describe("Job 없이 남은 파드", () => {
  test("남은 Job과 남은 파드의 안내가 다르다", async () => {
    const orphan = await plan({ pods: list(pod(JOB, INIT_LABELS, { status: { phase: "Succeeded" } })) });
    expect(orphan.code).toBe(1);
    expect(orphan.json.next).toBe("지난 초기화 파드의 결과(종료 코드)를 확인하고 그 파드를 지운 뒤 다시: homelab olive ledger-init(Job 없이 남은 파드는 스스로 지워지지 않는다)");
    const job = await plan({ jobs: [jobDoc(COMPLETE)] });
    expect(job.json.next).toBe("지난 초기화의 결과를 확인하고 Job을 지운 뒤 다시: homelab olive ledger-init(끝난 Job은 끝난 뒤 600초면 스스로 지워진다)");
  });
});
