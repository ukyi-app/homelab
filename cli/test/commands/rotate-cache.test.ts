import { describe, expect, test } from "bun:test";
import { FAKE_SECRETS, expectPlanReadOnly, ghGet, infisicalList, kubectlRule, runCli, type Rule } from "../harness";
import cmd from "../../src/commands/rotate-cache";
import { runIn, valkeyWorld } from "../fixtures/rotate-world/world";

const APP = "probe";
const NS = `app-${APP}`;
const FOLDER = `/apps/${APP}/valkey`;
const OLD = "fakevalue-valkey-old-aaaa-bbbb";

const file = (path: string, text: string | null): Rule =>
  text === null ? ghGet(`repos/ukyi-app/homelab/contents/${path}?ref=main`, 404, { message: "Not Found" }) : ghGet(`repos/ukyi-app/homelab/contents/${path}?ref=main`, 200, { type: "file", encoding: "base64", content: Buffer.from(text).toString("base64") });

function planRules(): Rule[] {
  return [
    file(`data/${APP}/values.yaml`, null),
    file(`apps/${APP}/values.yaml`, "chartVersion: 1.1.0\nport: 8080\nuses: { valkey: true }\ncache: { enabled: true }\n"),
    infisicalList(FOLDER, { PASSWORD: FAKE_SECRETS[0] }),
    kubectlRule(["-n", NS, "get", "secret", `${APP}-valkey-auth`, "-o", "json"], { stdout: JSON.stringify({ metadata: { resourceVersion: "5" }, data: { password: Buffer.from(FAKE_SECRETS[0]).toString("base64") } }) }),
  ];
}

describe("cache rotate: plan(PATH 스텁)", () => {
  test("시작 전 plan은 쓰기 0건, 값 없음", async () => {
    const r = await runCli(["cache", "rotate", APP, "--json"], planRules());
    expect(r.code).toBe(0);
    expectPlanReadOnly(r);
    expect(r.json.status).toBe("pending");
    expect(r.json.steps.map((s: { id: string }) => s.id)).toEqual(["registered", "baseline", "previous", "password", "auth-secret", "url-secret", "server-restart", "app-restart"]);
  });

  test("Valkey가 없는 앱은 실패하고 다음 행동을 준다", async () => {
    const rules = planRules().map((x, i) => (i === 1 ? file(`apps/${APP}/values.yaml`, "port: 8080\n") : x));
    const r = await runCli(["cache", "rotate", APP, "--json"], rules);
    expect(r.code).toBe(1);
    expectPlanReadOnly(r);
    expect(r.json.error.next).toBe(`homelab cache add ${APP}`);
  });
});

describe("cache rotate: 흐름(가짜 세계)", () => {
  for (const kind of ["cache", "persistent"] as const) {
    test(`${kind}: 시작 → 끝까지, 재실행 same, --finish가 옛 값을 지운다`, async () => {
      const w = valkeyWorld(APP, kind);
      const r = await runIn(w, cmd, "apply", { app: APP });
      expect(r.status).toBe("done");
      expect(r.next).toBe(`homelab cache rotate ${APP} --finish`);
      const cur = w.value(FOLDER, "PASSWORD")!;
      expect(cur).not.toBe(OLD);
      expect(w.valkeys.get(`${NS}/${APP}-valkey`)!.password).toBe(cur);
      // 서버를 먼저, 앱을 나중에(rotate.md 3d 3)
      expect(w.writes.filter((x) => x.startsWith("restartForSecrets"))).toEqual([`restartForSecrets ${NS}/${APP}-valkey`, `restartForSecrets ${NS}/${APP}`]);
      expect(JSON.stringify(r)).not.toContain(cur);

      w.writes = [];
      const again = await runIn(w, cmd, "apply", { app: APP });
      expect(again.status).toBe("same");
      expect(w.writes).toEqual([]);

      const fin = await runIn(w, cmd, "apply", { app: APP }, { finish: true });
      expect(fin.status).toBe("done");
      expect(w.value(FOLDER, "PASSWORD_PREVIOUS")).toBeUndefined();
      // 영속이면 지우기 전에 새 값으로 수동 백업 Job 하나를 돌리고 지운다(3d 4)
      expect(w.writes.some((x) => x.startsWith("createJobFromCronJob"))).toBe(kind === "persistent");
    });
  }

  test("서버 Secret 동기화 실패 → 뒤 단계 not-run, 재실행이 이어 간다", async () => {
    const w = valkeyWorld(APP, "cache");
    w.fail.set(`forceSync ${NS}/${APP}-valkey-auth`, "timeout");
    const r = await runIn(w, cmd, "apply", { app: APP });
    expect(r.status).toBe("failed");
    expect(r.steps.find((s) => s.id === "server-restart")!.result).toBe("not-run");
    const again = await runIn(w, cmd, "apply", { app: APP });
    expect(again.status).toBe("done");
    expect(w.value(FOLDER, "PASSWORD_PREVIOUS")).toBe(OLD);
  });

  test("영속: 수동 백업이 끝나지 않으면 --finish는 옛 값을 지우지 않는다", async () => {
    const w = valkeyWorld(APP, "persistent");
    await runIn(w, cmd, "apply", { app: APP });
    // Job 이름은 실행마다 달라 기다림 자체를 실패로 바꾼다.
    const orig = w.read.bind(w);
    w.read = (mode) => {
      const ctx = orig(mode);
      (ctx.k8s as any).waitCondition = () => false;
      return ctx;
    };
    const fin = await runIn(w, cmd, "apply", { app: APP }, { finish: true });
    expect(fin.status).toBe("failed");
    expect(w.value(FOLDER, "PASSWORD_PREVIOUS")).toBe(OLD);
  });
});
