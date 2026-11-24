// homelab olive test-job(시험 작업 넣기). 실제 클러스터에 닿지 않는다: kubectl은 PATH 스텁이다.
import { describe, expect, test } from "bun:test";
import { expectNoSecrets, expectPlanReadOnly, kubectlRule, rule, runCli, type Call, type Resp, type Rule } from "../harness";

const POD = "supervisor-7c9d8f6b5-x2k4q";
const RS = "supervisor-7c9d8f6b5";
const DEPLOY_UID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const RS_UID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const POD_UID = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
const SELECTOR = "app.kubernetes.io/name=olive,app.kubernetes.io/component=supervisor,homelab.ukyi.app/olive-target=supervisor";
const CANARY = "canary-raw-output-7f3a";
const REF = "0f0f0f0f-0000-4000-8000-000000000001";
const VALUES = ["8afa2150-81af-4018-9753-0183509606ad", "retry-1", "reader", "smoke_check", "input/1b5d2dd3-e830-49fd-bb90-4e93022446e8", "a".repeat(64)];
const EXEC = ["kubectl", "-n", "olive-control", "exec", POD, "-c", "supervisor", "--request-timeout=20s", "--", "bun", "src/main/admin.ts", "test-job", ...VALUES];
const CHECK_QUEUE = "같은 키로 다시 부르기 전에 homelab olive status --apply의 대기 수를 본다";

const json = (x: unknown): Resp => ({ stdout: JSON.stringify(x) });
const pod = { apiVersion: "v1", kind: "Pod", metadata: { name: POD, namespace: "olive-control", uid: POD_UID, labels: { "app.kubernetes.io/name": "olive", "app.kubernetes.io/component": "supervisor", "homelab.ukyi.app/olive-target": "supervisor" }, ownerReferences: [{ apiVersion: "apps/v1", kind: "ReplicaSet", name: RS, uid: RS_UID, controller: true }] }, spec: { containers: [{ name: "supervisor" }] }, status: { phase: "Running", conditions: [{ type: "Ready", status: "True" }] } };
const list = (...items: unknown[]): Resp => json({ kind: "List", metadata: {}, items });

function supervisor(exec: Resp | Resp[], pods: Resp = list(pod)): Rule[] {
  return [
    kubectlRule(["-n", "olive-control", "get", "pods", "-l", SELECTOR, "-o", "json"], pods),
    kubectlRule(["-n", "olive-control", "get", "deployments.apps", "supervisor", "-o", "json"], json({ apiVersion: "apps/v1", kind: "Deployment", metadata: { name: "supervisor", namespace: "olive-control", uid: DEPLOY_UID } })),
    kubectlRule(["-n", "olive-control", "get", "replicasets.apps", RS, "-o", "json"], json({ apiVersion: "apps/v1", kind: "ReplicaSet", metadata: { name: RS, namespace: "olive-control", uid: RS_UID, ownerReferences: [{ apiVersion: "apps/v1", kind: "Deployment", name: "supervisor", uid: DEPLOY_UID, controller: true }] } })),
    rule(EXEC, exec),
  ];
}

const created = (outcome = "created"): Resp => ({ stdout: `${JSON.stringify({ schema: "olive-test-job/v1", outcome, ref: REF })}\n` });
const entryExit = (code: number, line: string): Resp => ({ code, stderr: `${line}\ncommand terminated with exit code ${code}\n` });
const refused = (word: string) => entryExit(1, `olive admin: 감독이 요청을 거절했다(${word})`);
const jobUnknown = (head: string, word: string, code = 1) => entryExit(code, `olive admin: 시험 작업 모름: ${head}(${word})`);
const execCalls = (r: { calls: Call[] }) => r.calls.filter((c) => c.argv.includes("exec")).map((c) => c.argv);
const apply = (exec: Resp | Resp[], extra: string[] = [], pods?: Resp) => runCli(["olive", "test-job", ...VALUES, "--apply", "--json", ...extra], supervisor(exec, pods));

describe("plan", () => {
  test("plan은 대상 파드와 argv만 보이고 감독에 exec하지 않는다", async () => {
    const r = await runCli(["olive", "test-job", ...VALUES, "--json"], supervisor(created()));
    expect(r.code).toBe(0);
    expectPlanReadOnly(r);
    expect(execCalls(r)).toEqual([]);
    expect(r.json.body).toContain(`대상 파드 ${POD}`);
    expect(r.json.body).toContain(`실행: ${EXEC.join(" ")}`);
    expect(r.json.next).toBe(`homelab olive test-job ${VALUES.join(" ")} --apply`);
  });

  test("plan: 감독이 없거나 대조에 실패하면 1, 준비 전이면 3이다", async () => {
    const off = await runCli(["olive", "test-job", ...VALUES, "--json"], supervisor(created(), list()));
    expect([off.code, off.json.error.message]).toEqual([1, "시험 작업: 넣지 않았다. 감독이 꺼져 있다(파드 없음)"]);
    expectPlanReadOnly(off);
    const notReady = await runCli(["olive", "test-job", ...VALUES, "--json"], supervisor(created(), list({ ...pod, status: { phase: "Pending", conditions: [] } })));
    expect(notReady.code).toBe(3);
    expect(notReady.json.body).toContain("감독이 준비되지 않았다");
  });
});

describe("apply: 감독 진입점의 종료 코드 옮기기", () => {
  // [감독 진입점의 결과, CLI 종료 코드, 한 줄, 다음 행동]
  const rows: [string, Resp, number, string, string | null][] = [
    ["0 created", created(), 0, `시험 작업: 새로 넣음(참조 ${REF})`, null],
    ["0 existing", created("existing"), 0, `시험 작업: 같은 키·내용의 부탁이 이미 있다(참조 ${REF})`, null],
    ["3 restore_not_done", jobUnknown("감독이 복원을 마치지 않았다", "restore_not_done", 3), 3, "시험 작업: 넣지 않았다. 감독이 복원을 마치지 않았다(restore_not_done)", "감독이 복원을 마친 뒤 같은 명령을 다시 실행한다"],
    ["1 disabled", refused("disabled"), 1, "시험 작업 거절(disabled): 이 감독은 시험 작업 넣기가 꺼져 있다. 적힌 것 없음", "시험 클러스터의 감독에서만 쓴다(운영 값은 늘 꺼짐)"],
    ["1 conflict", refused("conflict"), 1, "시험 작업 거절(conflict): 같은 키에 다른 내용의 부탁이 있다. 적힌 것 없음", "다른 키를 쓴다"],
    ["1 limit", refused("limit"), 1, "시험 작업 거절(limit): 배정될 수 있는 대기 한도에 닿았다. 적힌 것 없음", "homelab olive status --apply의 대기 수가 줄면 다시"],
    ["1 owner_inactive", refused("owner_inactive"), 1, "시험 작업 거절(owner_inactive): 소유자 입력이 취소·만료됐다. 적힌 것 없음", "접수된 다른 입력을 소유자로 쓴다"],
    ["1 invariant_violation", refused("invariant_violation"), 1, "시험 작업 거절(invariant_violation): 장부가 거절했다(소유자가 접수된 입력이 아님 등). 적힌 것 없음", "원인을 고친 뒤 같은 명령을 다시 실행한다"],
    ["1 no_socket", jobUnknown("감독에 닿지 못했다", "no_socket"), 1, "시험 작업: 넣지 않았다. 감독에 닿지 못했다(no_socket)", "homelab olive status --apply로 감독을 확인한다"],
    ["1 timeout(답 없음)", jobUnknown("감독의 답을 받지 못했다", "timeout"), 1, "시험 작업: 결과 모름. 감독의 답을 받지 못했다(timeout). 장부에 적혔을 수 있다", CHECK_QUEUE],
    ["1 write_unknown", jobUnknown("장부에 적혔는지 모른다", "write_unknown"), 1, "시험 작업: 결과 모름. 장부에 적혔는지 모른다(write_unknown). 장부에 적혔을 수 있다", CHECK_QUEUE],
    ["1 ledger_unreadable", jobUnknown("감독이 상태를 읽지 못했다", "ledger_unreadable"), 1, "시험 작업: 넣지 않았다. 감독이 쓰기 전에 멈췄다(ledger_unreadable)", "원인을 고친 뒤 같은 명령을 다시 실행한다"],
    ["64 사용법", entryExit(64, "olive admin: 사용법: bun src/main/admin.ts status | test-job"), 1, "시험 작업: 넣지 않았다. 감독 진입점이 요청을 받지 않았다(종료 코드 64, CLI와 감독 이미지의 판이 다를 수 있다)", "원인을 고친 뒤 같은 명령을 다시 실행한다"],
    ["1 사유 꼴이 다름", entryExit(1, `olive admin: ${CANARY}`), 1, "시험 작업: 결과 모름. 감독 진입점이 종료 코드 1로 끝났다. 장부에 적혔을 수 있다", CHECK_QUEUE],
    ["7 모르는 코드", entryExit(7, `olive admin: 감독이 요청을 거절했다(busy)`), 1, "시험 작업: 결과 모름. 감독 진입점이 종료 코드 7로 끝났다. 장부에 적혔을 수 있다", CHECK_QUEUE],
    ["0 꼴이 다른 출력", { stdout: `{"schema":"olive-test-job/v1","outcome":"created","ref":"${CANARY}"}\n` }, 1, "시험 작업: 결과 모름. 실행했지만 감독의 답을 확인하지 못했다. 장부에 적혔을 수 있다", CHECK_QUEUE],
    ["kubectl 실패(원격 코드 없음)", { code: 1, stderr: `Error from server (Forbidden): ${CANARY}\n` }, 1, "시험 작업: 결과 모름. 실행했지만 감독의 답을 확인하지 못했다. 장부에 적혔을 수 있다", CHECK_QUEUE],
  ];

  test("표의 각 줄: 종료 코드·한 줄·다음 행동, exec는 한 번, 원문·가짜 시크릿 없음", async () => {
    for (const [name, resp, code, headline, next] of rows) {
      const r = await apply(resp);
      expect([name, r.code]).toEqual([name, code]);
      expect([name, r.json.body]).toEqual([name, headline]);
      expect([name, r.json.next]).toEqual([name, next]);
      if (code === 1) expect([name, r.json.error.message]).toEqual([name, headline]);
      expect([name, execCalls(r)]).toEqual([name, [EXEC]]);
      expect([name, `${r.stdout}${r.stderr}`.includes(CANARY)]).toEqual([name, false]);
      expectNoSecrets(r);
    }
  }, 120_000);

  test("kubectl 시간 초과는 결과 모름이고 다시 실행하지 않는다", async () => {
    const r = await apply({ sleepMs: 3_500 });
    expect(r.code).toBe(1);
    expect(r.json.body).toBe("시험 작업: 결과 모름. 실행했지만 감독의 답을 확인하지 못했다. 장부에 적혔을 수 있다");
    expect(execCalls(r)).toEqual([EXEC]);
  }, 30_000);

  test("감독이 없으면 실행하지 않는다", async () => {
    const r = await apply(created(), [], list());
    expect(r.code).toBe(1);
    expect(execCalls(r)).toEqual([]);
    expect(r.writes).toEqual([]);
  });

  test("기본은 한 줄이고 --verbose에서 감독 파드·종료 코드·사유를 보인다", async () => {
    const short = await apply(refused("conflict"));
    expect(short.json.body.split("\n")).toHaveLength(1);
    const long = await apply(refused("conflict"), ["--verbose"]);
    expect(long.json.body.split("\n")).toEqual(["시험 작업 거절(conflict): 같은 키에 다른 내용의 부탁이 있다. 적힌 것 없음", `감독 파드 ${POD}`, "진입점 종료 코드 1", "사유 refused conflict"]);
    const ok = await apply(created(), ["--verbose"]);
    expect(ok.json.body.split("\n")).toEqual([`시험 작업: 새로 넣음(참조 ${REF})`, `감독 파드 ${POD}`]);
  }, 30_000);

  test("사람용 출력도 쓰기는 감독 exec 하나뿐이다", async () => {
    const r = await runCli(["olive", "test-job", ...VALUES, "--apply"], supervisor(created()));
    expect(r.code).toBe(0);
    expect(r.writes.map((c) => c.argv)).toEqual([EXEC]);
    expect(`${r.stdout}${r.stderr}`).toContain(`새로 넣음(참조 ${REF})`);
    expectNoSecrets(r);
  });
});

describe("인자 거르기", () => {
  test("빈 값·공백·제어 문자·따옴표·긴 값·요청 한 줄 초과·인자 수가 틀리면 64이고 아무것도 부르지 않는다", async () => {
    const at = (i: number, v: string) => VALUES.map((x, j) => (j === i ? v : x));
    const cases: [string, string[]][] = [
      ["빈 값", at(1, "")],
      ["공백", at(1, `a ${CANARY}`)],
      ["탭", at(2, "a\tb")],
      ["줄바꿈", at(3, `a\n${CANARY}`)],
      ["따옴표", at(1, 'a"b')],
      ["역슬래시", at(1, "a\\b")],
      ["ASCII 밖", at(2, "역할")],
      ["201자", at(1, "k".repeat(201))],
      ["요청 한 줄 초과", ["o".repeat(200), "k".repeat(200), "r".repeat(200), "p".repeat(200), "s".repeat(200), "d".repeat(64)]],
      ["다섯 개", VALUES.slice(0, 5)],
      ["일곱 개", [...VALUES, "extra"]],
    ];
    for (const [name, values] of cases) {
      for (const mode of [[], ["--apply"]]) {
        const r = await runCli(["olive", "test-job", ...values, ...mode, "--json"], supervisor(created()));
        expect([name, mode, r.code]).toEqual([name, mode, 64]);
        expect([name, r.calls]).toEqual([name, []]);
        expect([name, `${r.stdout}${r.stderr}`.includes(CANARY)]).toEqual([name, false]);
      }
    }
  }, 120_000);
});
