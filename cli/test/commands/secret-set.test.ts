import { describe, expect, test } from "bun:test";
import { argvFor as infArgv } from "../../src/core/infisical";
import { FAKE_PROJECT, FAKE_SECRETS, expectNoSecrets, expectPlanReadOnly, infisicalSet, rule, runCli, type Rule } from "../harness";
import { createFolder, folderJson, folders, homelab, infisicalList } from "../fixtures/app-add-world/world";

// 타임아웃 주입(스텁 5초 지연 > exec 상한 3초)이 든 시험은 3초를 넘는다. bun 기본 시험 제한(5초)에 걸리지 않게 늘린다.
const SLOW = 20_000;
const APP = "memo";
const F = `/apps/${APP}`;
const listed = (v?: string) => ({ stdout: JSON.stringify(v === undefined ? [] : [{ secretKey: "API_TOKEN", secretValue: v }]) });

function world(o: { list: ReturnType<typeof listed>[]; values?: string | null; setCode?: number; setSleep?: number; noFolder?: boolean }): Rule[] {
  return [
    ...homelab({ [`apps/${APP}/values.yaml`]: o.values ?? null }),
    ...(o.noFolder ? [rule(infArgv.folders(FAKE_PROJECT, "/apps"), [...Array(4).fill({ stdout: folderJson("/apps", []) }), { stdout: folderJson("/apps", [APP]) }]), folders({ "/": ["apps"] })].flat() : folders({ "/apps": [APP] })),
    createFolder("/apps", APP),
    infisicalList(F, o.list),
    { ...infisicalSet(F, { code: o.setCode ?? 0, sleepMs: o.setSleep }), captureStdin: true },
  ];
}

describe("secret set", () => {
  test("plan: 없으면 저장 계획, stdin을 읽지 않고 쓰기 0건", async () => {
    const r = await runCli(["secret", "set", APP, "API_TOKEN", "--json"], world({ list: [listed()] }), { stdin: `${FAKE_SECRETS[0]}\n` });
    expect(r.code).toBe(0);
    expectPlanReadOnly(r);
    expect(r.json.steps[0].state).toBe("missing");
  });

  test("apply: 값은 stdin → Infisical 요청 본문으로만, argv·출력에 없다", async () => {
    const r = await runCli(["secret", "set", APP, "API_TOKEN", "--apply", "--json"], world({ list: [listed(), listed(), listed(FAKE_SECRETS[0])] }), { stdin: `${FAKE_SECRETS[0]}\n` });
    expect(r.code).toBe(0);
    const set = r.calls.find((c) => c.argv.join(" ") === infArgv.set(FAKE_PROJECT, F).join(" "))!;
    expect(set.stdin).toBe(`API_TOKEN=${FAKE_SECRETS[0]}\n`);
    expectNoSecrets({ ...r, calls: r.calls.filter((c) => c !== set) });
  });

  test("폴더가 없으면 만들고 쓴다", async () => {
    const r = await runCli(["secret", "set", APP, "API_TOKEN", "--apply", "--json"], world({ list: [listed(FAKE_SECRETS[0])], noFolder: true }), { stdin: `${FAKE_SECRETS[0]}\n` });
    expect(r.calls.some((c) => c.argv.join(" ") === infArgv.createFolder(FAKE_PROJECT, "/apps", APP).join(" "))).toBe(true);
    expect(r.code).toBe(0);
  });

  test("있으면 --replace 없이 same(쓰지 않고 stdin도 안 읽는다), --replace면 바꾼다", async () => {
    const kept = await runCli(["secret", "set", APP, "API_TOKEN", "--apply", "--json"], world({ list: [listed(FAKE_SECRETS[1])] }), { stdin: `${FAKE_SECRETS[0]}\n` });
    expect(kept.code).toBe(0);
    expect(kept.json.steps[0].state).toBe("same");
    expect(kept.writes).toEqual([]);
    const replaced = await runCli(["secret", "set", APP, "API_TOKEN", "--replace", "--apply", "--json"], world({ list: [listed(FAKE_SECRETS[1]), listed(FAKE_SECRETS[1]), listed(FAKE_SECRETS[0])] }), { stdin: `${FAKE_SECRETS[0]}\n` });
    expect(replaced.code).toBe(0);
    expect(replaced.json.steps[0].result).toBe("applied");
  });

  test("짧은 값·쓰기 실패는 exit 1, 쓰기 타임아웃은 재조회", async () => {
    const short = await runCli(["secret", "set", APP, "API_TOKEN", "--apply", "--json"], world({ list: [listed()] }), { stdin: "short\n" });
    expect(short.code).toBe(1);
    expect(short.writes).toEqual([]);
    const failed = await runCli(["secret", "set", APP, "API_TOKEN", "--apply", "--json"], world({ list: [listed()], setCode: 1 }), { stdin: `${FAKE_SECRETS[0]}\n` });
    expect(failed.code).toBe(1);
    const slow = await runCli(["secret", "set", APP, "API_TOKEN", "--apply", "--json"], world({ list: [listed(), listed(), listed(FAKE_SECRETS[0])], setSleep: 5000 }), { stdin: `${FAKE_SECRETS[0]}\n` });
    expect(slow.code).toBe(0);
    expect(slow.json.notes.join(" ")).toContain("시간 초과 뒤 다시 읽어");
  }, SLOW);

  test("--replace 쓰기가 시간 초과여도 반영됐으면 성공, 반영 안 됐으면 실패(기대 해시는 쓰기 전에, #884 P2-3)", async () => {
    const reflected = await runCli(["secret", "set", APP, "API_TOKEN", "--replace", "--apply", "--json"], world({ list: [listed(FAKE_SECRETS[1]), listed(FAKE_SECRETS[1]), listed(FAKE_SECRETS[0])], setSleep: 5000 }), { stdin: `${FAKE_SECRETS[0]}\n` });
    expect(reflected.code).toBe(0);
    expect(reflected.json.notes.join(" ")).toContain("시간 초과 뒤 다시 읽어");
    expect(reflected.calls.filter((c) => c.argv.join(" ") === infArgv.set(FAKE_PROJECT, F).join(" ")).length).toBe(1);
    const lost = await runCli(["secret", "set", APP, "API_TOKEN", "--replace", "--apply", "--json"], world({ list: [listed(FAKE_SECRETS[1])], setSleep: 5000 }), { stdin: `${FAKE_SECRETS[0]}\n` });
    expect(lost.code).toBe(1);
    expect(lost.json.error.message).toContain("시간 초과 뒤 다시 읽었지만");
  }, SLOW);

  test("등록된 앱의 secrets에 키가 없으면 알리고, 끝나면 secret sync로 안내", async () => {
    const values = "chartVersion: 1.1.0\nkind: web\nport: 8080\nresources: { cpu: 50m, memory: 64Mi }\n";
    const r = await runCli(["secret", "set", APP, "API_TOKEN", "--apply", "--json"], world({ list: [listed(), listed(), listed(FAKE_SECRETS[0])], values }), { stdin: `${FAKE_SECRETS[0]}\n` });
    expect(r.code).toBe(0);
    expect(r.json.notes.join(" ")).toContain(`homelab app add ${APP}`);
    expect(r.json.next).toBe(`homelab secret sync ${APP}`);
  });
});
