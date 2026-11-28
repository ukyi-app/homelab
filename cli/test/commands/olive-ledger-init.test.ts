// homelab olive ledger-init(장부 초기화 일회성 Job). 실제 클러스터에 닿지 않는다: kubectl은 PATH 스텁이다.
import { describe, expect, test } from "bun:test";
import { kubectlArgv } from "../../src/core/kubectl";
import { expectNoSecrets, expectPlanReadOnly, kubectlRule, rule, runCli, type Call, type Resp, type Rule } from "../harness";

const NS = "olive-control";
const JOB = "olive-ledger-init";
const JOB_UID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
const IMAGE = `ghcr.io/ukyi-app/olive@sha256:${"1".repeat(64)}`;
const CANARY = "canary-raw-output-5c1d";
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

const quota = (hard = { cpu: "500m", memory: "768Mi" }, used: Record<string, string> | null = { "limits.cpu": "0", "limits.memory": "0" }) =>
  json({ apiVersion: "v1", kind: "ResourceQuota", metadata: { name: "olive-limits", namespace: NS }, spec: { hard: { "limits.cpu": hard.cpu, "limits.memory": hard.memory } }, ...(used ? { status: { used } } : {}) });
const pvc = (name = "ledger", extra: Record<string, unknown> = {}) => json({ apiVersion: "v1", kind: "PersistentVolumeClaim", metadata: { name, namespace: NS, ...extra }, status: { phase: "Bound" } });
const lock = (extra: Record<string, unknown> = {}) => json({ apiVersion: "v1", kind: "ResourceQuota", metadata: { name: "olive-stop", namespace: NS, labels: { "homelab.ukyi.app/olive-stop": "lock" }, ...extra }, spec: { hard: { pods: "0" } } });
const pod = (name: string, labels: Record<string, string>, extra: Record<string, unknown> = {}) => ({ apiVersion: "v1", kind: "Pod", metadata: { name, namespace: NS, uid: "dddddddd-dddd-4ddd-8ddd-dddddddddddd", labels }, spec: { volumes: [{ name: "ledger", persistentVolumeClaim: { claimName: "ledger" } }] }, status: { phase: "Running" }, ...extra });
const jobDoc = (conditions: unknown[] = []) => json({ apiVersion: "batch/v1", kind: "Job", metadata: { name: JOB, namespace: NS, uid: JOB_UID }, status: { conditions } });
const COMPLETE = [{ type: "Complete", status: "True" }];
const FAILED = [{ type: "Failed", status: "True", reason: "BackoffLimitExceeded" }];
const DEADLINE = [{ type: "Failed", status: "True", reason: "DeadlineExceeded" }];
const initPod = (state: Record<string, unknown>) =>
  list({ apiVersion: "v1", kind: "Pod", metadata: { name: `${JOB}-x7k2p`, namespace: NS, labels: { ...INIT_LABELS, "batch.kubernetes.io/controller-uid": JOB_UID } }, status: { phase: "Failed", containerStatuses: [{ name: "ledger-init", state }] } });
const exited = (exitCode: number, message?: string, reason = exitCode === 0 ? "Completed" : "Error") => initPod({ terminated: { exitCode, reason, ...(message ? { message } : {}) } });

const CREATE = kubectlArgv(["-n", NS, "create", "-f", "-", "-o", "json"]);
const DELETE = kubectlArgv(["delete", "--raw", `/apis/batch/v1/namespaces/${NS}/jobs/${JOB}`, "-f", "-"]);

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
};

function world(w: World = {}): Rule[] {
  return [
    rule(["kubectl", "config", "current-context"], { stdout: "test-cluster\n" }),
    kubectlRule(["-n", NS, "get", "deployments.apps", "supervisor", "-o", "json"], w.deploy ?? json(deployment())),
    kubectlRule(["-n", NS, "get", "pods", "-o", "json"], w.pods ?? list()),
    kubectlRule(["-n", NS, "get", "resourcequotas", "olive-stop", "-o", "json"], w.stopLock ?? notFound('resourcequotas "olive-stop"')),
    kubectlRule(["-n", NS, "get", "jobs.batch", JOB, "-o", "json"], w.jobs ?? [notFound(`jobs.batch "${JOB}"`), jobDoc(COMPLETE), notFound(`jobs.batch "${JOB}"`)]),
    kubectlRule(["-n", NS, "get", "resourcequotas", "olive-limits", "-o", "json"], w.quota ?? quota()),
    kubectlRule(["-n", NS, "get", "persistentvolumeclaims", "ledger", "-o", "json"], w.pvc ?? pvc()),
    kubectlRule(["-n", NS, "get", "persistentvolumeclaims", "ledger-2", "-o", "json"], pvc("ledger-2")),
    kubectlRule(["-n", NS, "get", "pods", "-l", `batch.kubernetes.io/controller-uid=${JOB_UID}`, "-o", "json"], w.initPods ?? exited(0)),
    rule(CREATE, w.create ?? json({ apiVersion: "batch/v1", kind: "Job", metadata: { name: JOB, namespace: NS, uid: JOB_UID } }), { captureStdin: true }),
    rule(DELETE, w.remove ?? json({ kind: "Status", status: "Success" }), { captureStdin: true }),
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
    ["지난 초기화 파드", { pods: list(pod(`${JOB}-old`, INIT_LABELS, { status: { phase: "Succeeded" } })) }, 1, "지난 초기화 파드가 남아 있다(1개)", "Job을 지운 뒤 다시"],
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
    ["94 잠김", FAILED, exited(94, "olive ledger-init 0.1.0: 장부를 만들지 못했다(open:locked)\n"), 1, "장부 초기화 실패: 장부를 만들지 못했다(종료 94, open:locked)", "자동으로 다시 돌리지 않았다"],
    ["94 닫기 실패", FAILED, exited(94, "olive ledger-init 0.1.0: 장부를 만들지 못했다(close:threw)\n"), 1, "장부 초기화 실패: 장부를 만들지 못했다(종료 94, close:threw). 장부가 만들어졌을 수 있다", "자동으로 다시 돌리지 않았다"],
    ["94 사유 꼴이 다름", FAILED, exited(94, `olive ledger-init 0.1.0: ${CANARY}\n`), 1, "장부 초기화 실패: 장부를 만들지 못했다(종료 94, 사유를 읽지 못함). 장부가 만들어졌을 수 있다", "자동으로 다시 돌리지 않았다"],
    ["91 환경", FAILED, exited(91, "olive ledger-init 0.1.0: 환경 OLIVE_LEDGER_DIR이(가) 없다\n"), 1, "장부 초기화 실패: 초기화 진입점이 장부 경로 환경을 받지 못했다(종료 91, env:missing)", "OLIVE_LEDGER_DIR을 확인"],
    ["64 사용법", FAILED, exited(64, "olive ledger-init 0.1.0: 사용법: bun src/main/ledger-init.ts (인자 없음)\n"), 1, "장부 초기화 실패: 초기화 진입점이 실행을 받지 않았다(종료 64, CLI와 감독 이미지의 판이 다를 수 있다)", "CLI와 차트의 판"],
    ["137 메모리 초과", FAILED, exited(137, undefined, "OOMKilled"), 1, "장부 초기화 실패: 초기화 파드가 종료 137로 끝났다(OOMKilled). 장부가 만들어졌을 수 있다", "다시 불러 확인한다"],
    ["기한 넘김", DEADLINE, list(), 1, "장부 초기화: 결과 모름. 초기화 파드가 기한 안에 끝나지 않았다. 장부가 만들어졌을 수 있다", "다시 불러 확인한다"],
    ["파드를 읽지 못함", FAILED, { code: 1, stderr: `Error from server (Forbidden): ${CANARY}\n` }, 1, "장부 초기화: 결과 모름. Job 상태를 읽지 못했다. 장부가 만들어졌을 수 있다", "Job이 끝나고 지워진 뒤"],
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
