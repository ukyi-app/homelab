import { describe, expect, test } from "bun:test";
import { FAKE_SECRETS, expectNoSecrets, expectPlanReadOnly, ghGet, infisicalList, kubectlRule, runCli, type Rule } from "../harness";
import cmd from "../../src/commands/rotate-db";
import { postgresWorld, runIn } from "../fixtures/rotate-world/world";

const APP = "probe";
const FOLDER = `/apps/${APP}/postgres`;
const OLD = "fakevalue-postgres-old-aaaa-bbbb";

const file = (path: string, text: string | null): Rule =>
  text === null ? ghGet(`repos/ukyi-app/homelab/contents/${path}?ref=main`, 404, { message: "Not Found" }) : ghGet(`repos/ukyi-app/homelab/contents/${path}?ref=main`, 200, { type: "file", encoding: "base64", content: Buffer.from(text).toString("base64") });

// 회전 시작 전 plan이 읽는 것. 비밀번호 자리에 가짜 시크릿을 둬 출력·argv에 새지 않는지 본다.
function planRules(roleValue = FAKE_SECRETS[0]): Rule[] {
  return [
    file(`data/${APP}/values.yaml`, "chartVersion: 1.0.1\npostgres: { enabled: true }\n"),
    file(`apps/${APP}/values.yaml`, "chartVersion: 1.1.0\nport: 8080\nuses: { postgres: true }\n"),
    infisicalList(FOLDER, { PASSWORD: FAKE_SECRETS[0] }),
    kubectlRule(["-n", "database", "get", "databaseroles.postgresql.cnpg.io", APP, "-o", "json"], { stdout: JSON.stringify({ status: { applied: true, secretResourceVersion: "5" } }) }),
    kubectlRule(["-n", "database", "get", "secret", `pg-role-${APP}`, "-o", "json"], { stdout: JSON.stringify({ metadata: { resourceVersion: "5" }, data: { username: Buffer.from(APP).toString("base64"), password: Buffer.from(roleValue).toString("base64") } }) }),
  ];
}

describe("db rotate: plan(PATH 스텁)", () => {
  test("시작 전 plan은 쓰기 0건, 비밀번호가 출력·argv에 없다, 다음은 --apply", async () => {
    const r = await runCli(["db", "rotate", APP, "--json"], planRules());
    expect(r.code).toBe(0);
    expectPlanReadOnly(r);
    expect(r.json.status).toBe("pending");
    expect(r.json.steps.map((s: { id: string }) => s.id)).toEqual(["registered", "baseline", "previous", "password", "role-secret", "role-applied", "app-secret", "app-restart"]);
    expect(r.json.next).toBe(`homelab db rotate ${APP} --apply`);
    // T13 S8: 실패 창이 T11 17~20초보다 긴 약 35초였다. 근거와 함께 범위로 알린다.
    expect(r.json.notes.join(" ")).toContain("수십 초다(T11 약 17~20초, T13 약 35초)");
  });

  test("Infisical과 역할 Secret이 다르면 아무것도 쓰기 전에 실패(exit 1)", async () => {
    const r = await runCli(["db", "rotate", APP, "--json"], planRules(FAKE_SECRETS[1]));
    expect(r.code).toBe(1);
    expectPlanReadOnly(r);
    expect(r.json.error.message).toContain("다르다");
  });

  test("사람용 출력에도 값이 없다", async () => {
    const r = await runCli(["db", "rotate", APP], planRules());
    expect(r.code).toBe(0);
    expectPlanReadOnly(r);
    expect(r.stdout).toContain("PASSWORD_PREVIOUS");
  });

  test("--finish plan(기록 없음)은 same", async () => {
    const r = await runCli(["db", "rotate", APP, "--finish", "--json"], planRules());
    expect(r.code).toBe(0);
    expectPlanReadOnly(r);
    expect(r.json.status).toBe("same");
  });
});

describe("db rotate: 흐름(가짜 세계)", () => {
  test("시작 → 끝까지, 재실행은 모두 same·쓰기 0, --finish가 옛 값을 지운다", async () => {
    const w = postgresWorld(APP);
    const plan = await runIn(w, cmd, "plan", { app: APP });
    expect(plan.status).toBe("pending");
    expect(w.writes).toEqual([]);

    const r = await runIn(w, cmd, "apply", { app: APP });
    expect(r.status).toBe("done");
    expect(r.next).toBe(`homelab db rotate ${APP} --finish`);
    expect(w.value(FOLDER, "PASSWORD_PREVIOUS")).toBe(OLD);
    const cur = w.value(FOLDER, "PASSWORD")!;
    expect(cur).not.toBe(OLD);
    expect(w.roles.get(APP)!.password).toBe(cur);
    expect(w.secret(`app-${APP}`, `${APP}-db`)!.data.DATABASE_URL).toContain(cur);
    // 순서: 옛 값 보존 → 새 값 → DB 쪽 → 앱 쪽 → 재시작(C.6.5)
    expect(w.writes).toEqual([`infisical set ${FOLDER}/PASSWORD_PREVIOUS`, "generatePassword", `infisical set ${FOLDER}/PASSWORD`, `forceSync database/pg-role-${APP}`, `forceSync app-${APP}/${APP}-db`, `restartForSecrets app-${APP}/${APP}`]);
    expect(JSON.stringify(r)).not.toContain(cur);
    expect(JSON.stringify(r)).not.toContain(OLD);

    w.writes = [];
    const again = await runIn(w, cmd, "apply", { app: APP });
    expect(again.status).toBe("same");
    expect(again.steps.every((s) => s.state === "same")).toBe(true);
    expect(w.writes).toEqual([]);

    const fin = await runIn(w, cmd, "apply", { app: APP }, { finish: true });
    expect(fin.status).toBe("done");
    expect(w.value(FOLDER, "PASSWORD_PREVIOUS")).toBeUndefined();
    expect(w.value(FOLDER, "PASSWORD")).toBe(cur);

    w.writes = [];
    const fin2 = await runIn(w, cmd, "apply", { app: APP }, { finish: true });
    expect(fin2.status).toBe("same");
    expect(w.writes).toEqual([]);
  });

  test("중간 실패(앱 연결 Secret 동기화)면 exit 1·뒤 단계 not-run, 재실행이 이어서 끝낸다", async () => {
    const w = postgresWorld(APP);
    w.fail.set(`forceSync app-${APP}/${APP}-db`, new Error("annotate 실패(주입)"));
    const r = await runIn(w, cmd, "apply", { app: APP });
    expect(r.status).toBe("failed");
    const byId = Object.fromEntries(r.steps.map((s) => [s.id, s.result]));
    // 가짜 CNPG는 동기화와 함께 적용해 이 단계는 이미 same이다.
    expect(byId["role-secret"]).toBe("applied");
    expect(byId["app-secret"]).toBe("failed");
    expect(byId["app-restart"]).toBe("not-run");
    const cur = w.value(FOLDER, "PASSWORD")!;

    w.writes = [];
    const again = await runIn(w, cmd, "apply", { app: APP });
    expect(again.status).toBe("done");
    // 이미 된 것(옛 값 보존, 새 값, DB 쪽)은 다시 하지 않는다. 새 값을 또 만들지 않는다.
    expect(w.writes).toEqual([`forceSync app-${APP}/${APP}-db`, `restartForSecrets app-${APP}/${APP}`]);
    expect(w.value(FOLDER, "PASSWORD")).toBe(cur);
  });

  test("Infisical 쓰기 시간 초과는 재시도하지 않고 다시 읽어 실패(결과 미상), 재실행으로 이어진다", async () => {
    const w = postgresWorld(APP);
    w.fail.set(`infisical set ${FOLDER}/PASSWORD`, "timeout");
    const r = await runIn(w, cmd, "apply", { app: APP });
    expect(r.status).toBe("failed");
    expect(r.error!.message).toContain("결과 미상");
    expect(w.writes.filter((x) => x === `infisical set ${FOLDER}/PASSWORD`)).toHaveLength(1);
    const again = await runIn(w, cmd, "apply", { app: APP });
    expect(again.status).toBe("done");
    // 옛 값은 처음 한 번 옮긴 그대로다(새 값으로 덮지 않았다).
    expect(w.value(FOLDER, "PASSWORD_PREVIOUS")).toBe(OLD);
  });

  test("CNPG가 적용하지 않으면 역할 단계에서 멈춘다(앱 쪽은 건드리지 않는다)", async () => {
    const w = postgresWorld(APP);
    w.cnpgApplies = false;
    const r = await runIn(w, cmd, "apply", { app: APP });
    expect(r.status).toBe("failed");
    expect(r.steps.find((s) => s.id === "role-applied")!.result).toBe("failed");
    expect(w.writes).not.toContain(`forceSync app-${APP}/${APP}-db`);
  });

  test("재시작 뒤 헬스가 실패하면 실패하고, --finish는 다시 확인하기 전에는 옛 값을 지우지 않는다", async () => {
    const w = postgresWorld(APP);
    w.fail.set("appStatus", new Error("port-forward 실패(주입)"));
    const r = await runIn(w, cmd, "apply", { app: APP });
    expect(r.status).toBe("failed");
    w.fail.set("appStatus", new Error("port-forward 실패(주입)"));
    const fin = await runIn(w, cmd, "apply", { app: APP }, { finish: true });
    expect(fin.status).toBe("failed");
    expect(w.value(FOLDER, "PASSWORD_PREVIOUS")).toBe(OLD);
    const fin2 = await runIn(w, cmd, "apply", { app: APP }, { finish: true });
    expect(fin2.status).toBe("done");
    expect(w.value(FOLDER, "PASSWORD_PREVIOUS")).toBeUndefined();
  });

  test("--finish는 회전이 반영되지 않았으면 아무것도 지우지 않는다", async () => {
    const w = postgresWorld(APP);
    w.setValue(FOLDER, "PASSWORD_PREVIOUS", OLD);
    w.setValue(FOLDER, "PASSWORD", "fakevalue-postgres-new-cccc-dddd");
    const r = await runIn(w, cmd, "apply", { app: APP }, { finish: true });
    expect(r.status).toBe("failed");
    expect(r.error!.next).toBe(`homelab db rotate ${APP} --apply`);
    expect(w.writes).toEqual([]);
  });

  test("회전 중 PASSWORD를 읽지 못하면(없음) 쓰기 없이 실패한다", async () => {
    const w = postgresWorld(APP);
    w.setValue(FOLDER, "PASSWORD_PREVIOUS", OLD);
    w.infisical.get(FOLDER)!.delete("PASSWORD");
    const r = await runIn(w, cmd, "apply", { app: APP });
    expect(r.status).toBe("failed");
    expect(w.writes).toEqual([]);
    const f = await runIn(w, cmd, "apply", { app: APP }, { finish: true });
    expect(f.status).toBe("failed");
    expect(w.value(FOLDER, "PASSWORD_PREVIOUS")).toBe(OLD);
  });

  test("가짜 시크릿 꼴 값도 결과에 없다", async () => {
    const w = postgresWorld(APP, { password: FAKE_SECRETS[0] });
    const r = await runIn(w, cmd, "apply", { app: APP });
    expect(r.status).toBe("done");
    expectNoSecrets({ stdout: JSON.stringify(r), calls: [] });
  });
});
