// restore-check 결과 기록 어댑터(T24 계약 2). argv는 Cluster database/pg의 annotate 하나, 키는 두 개뿐,
// fail은 pass 키를 건드리지 않는다. 값 스키마 밖이면 쓰기 0건, 되읽기가 다르면 실패.
import { describe, expect, test } from "bun:test";
import type { RestoreCheckMark } from "../../src/core/command";
import { RESTORE_CHECK_LAST, RESTORE_CHECK_PASS, restoreCheckValue } from "../../src/core/kubectl";
import { applyWith, kubectlRule, testCtx } from "../harness";

const UID = "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0";
const pass: RestoreCheckMark = { run: "run1", result: "pass", at: "2026-11-03T06:00:00Z", target: "2026-11-03T05:10:00Z", server: "pg-20261023", dbs: 2 };
const fail: RestoreCheckMark = { ...pass, result: "fail", dbs: 0, reason: "aborted" };
const getPg = ["-n", "database", "get", "clusters.postgresql.cnpg.io", "pg", "-o", "json"];
const pgDoc = (annotations: Record<string, string> = {}, uid = UID) => ({ stdout: JSON.stringify({ metadata: { name: "pg", uid, annotations: { "argocd.argoproj.io/sync-options": "Prune=false,Delete=false", ...annotations } } }) });
const annotate = (pairs: string[]) => kubectlRule(["-n", "database", "annotate", "clusters.postgresql.cnpg.io", "pg", ...pairs, "--overwrite"]);

describe("restoreCheckValue", () => {
  test("키 순서 고정·공백 없는 한 줄 JSON, reason은 fail에만 끝에", () => {
    expect(restoreCheckValue(pass, UID)).toBe(`{"v":1,"run":"run1","result":"pass","at":"2026-11-03T06:00:00Z","target":"2026-11-03T05:10:00Z","server":"pg-20261023","dbs":2,"cluster":"${UID}"}`);
    expect(restoreCheckValue(fail, UID)).toBe(`{"v":1,"run":"run1","result":"fail","at":"2026-11-03T06:00:00Z","target":"2026-11-03T05:10:00Z","server":"pg-20261023","dbs":0,"cluster":"${UID}","reason":"aborted"}`);
  });

  test("스키마 밖 값은 던진다", () => {
    const bad: [Partial<RestoreCheckMark> & Record<string, unknown>, string][] = [
      [{ extra: "x" }, "없는 필드"],
      [{ run: "RUN 1" }, "실행 id"],
      [{ result: "ok" as never }, "pass·fail"],
      [{ at: "2026-11-03T06:00:00.123Z" }, "RFC3339"],
      [{ target: "2026-11-03 05:10:00+00" }, "RFC3339"],
      [{ server: "pg_x" }, "server"],
      [{ dbs: -1 }, "dbs"],
      [{ dbs: 1.5 }, "dbs"],
      [{ reason: "aborted" }, "reason을 두지 않는다"],
    ];
    for (const [patch, msg] of bad) expect(() => restoreCheckValue({ ...pass, ...patch } as RestoreCheckMark, UID)).toThrow(msg);
    expect(() => restoreCheckValue({ ...fail, reason: undefined }, UID)).toThrow("reason");
    expect(() => restoreCheckValue({ ...fail, reason: "Bad Reason" as never }, UID)).toThrow("reason");
    expect(() => restoreCheckValue(pass, "")).toThrow("uid");
  });
});

describe("kubeWrite.restoreCheckMark", () => {
  test("pass: pg에 annotate 하나로 두 키만 쓰고 되읽어 확인한다. 그 밖의 쓰기 0건", async () => {
    const v = restoreCheckValue(pass, UID);
    const { ctx, calls } = testCtx("apply", [kubectlRule(getPg, [pgDoc(), pgDoc({ [RESTORE_CHECK_LAST]: v, [RESTORE_CHECK_PASS]: v })]), annotate([`${RESTORE_CHECK_LAST}=${v}`, `${RESTORE_CHECK_PASS}=${v}`])]);
    await applyWith(ctx, (w) => w.k8s.restoreCheckMark(pass));
    const c = calls();
    expect(c.unmatched).toEqual([]);
    expect(c.writes.map((x) => x.argv)).toEqual([["kubectl", "-n", "database", "annotate", "clusters.postgresql.cnpg.io", "pg", `${RESTORE_CHECK_LAST}=${v}`, `${RESTORE_CHECK_PASS}=${v}`, "--overwrite", "--request-timeout=20s"]]);
  });

  test("fail: last 키만 쓴다(pass 키는 argv에 없다)", async () => {
    const v = restoreCheckValue(fail, UID);
    const old = restoreCheckValue(pass, UID);
    const { ctx, calls } = testCtx("apply", [kubectlRule(getPg, [pgDoc({ [RESTORE_CHECK_PASS]: old }), pgDoc({ [RESTORE_CHECK_PASS]: old, [RESTORE_CHECK_LAST]: v })]), annotate([`${RESTORE_CHECK_LAST}=${v}`])]);
    await applyWith(ctx, (w) => w.k8s.restoreCheckMark(fail));
    const writes = calls().writes.map((x) => x.argv);
    expect(writes).toHaveLength(1);
    expect(writes[0].some((a) => a.startsWith(RESTORE_CHECK_PASS))).toBe(false);
  });

  test("스키마 밖 값이면 쓰기 0건", async () => {
    const { ctx, calls } = testCtx("apply", [kubectlRule(getPg, pgDoc())]);
    await expect(applyWith(ctx, (w) => w.k8s.restoreCheckMark({ ...pass, reason: "aborted" }))).rejects.toThrow("reason");
    await expect(applyWith(ctx, (w) => w.k8s.restoreCheckMark({ ...pass, server: "a b" }))).rejects.toThrow("server");
    expect(calls().writes).toEqual([]);
  });

  test("되읽은 값이 다르거나 pg uid가 바뀌었으면 실패", async () => {
    const v = restoreCheckValue(pass, UID);
    const pairs = [`${RESTORE_CHECK_LAST}=${v}`, `${RESTORE_CHECK_PASS}=${v}`];
    const lost = testCtx("apply", [kubectlRule(getPg, [pgDoc(), pgDoc({ [RESTORE_CHECK_LAST]: v })]), annotate(pairs)]);
    await expect(applyWith(lost.ctx, (w) => w.k8s.restoreCheckMark(pass))).rejects.toThrow(RESTORE_CHECK_PASS);
    const moved = testCtx("apply", [kubectlRule(getPg, [pgDoc(), pgDoc({ [RESTORE_CHECK_LAST]: v, [RESTORE_CHECK_PASS]: v }, "11111111-2222-3333-4444-555555555555")]), annotate(pairs)]);
    await expect(applyWith(moved.ctx, (w) => w.k8s.restoreCheckMark(pass))).rejects.toThrow("다른 객체");
  });

  test("pg가 없으면 쓰지 않고 실패", async () => {
    const { ctx, calls } = testCtx("apply", [kubectlRule(getPg, { code: 1, stderr: 'Error from server (NotFound): clusters.postgresql.cnpg.io "pg" not found\n' })]);
    await expect(applyWith(ctx, (w) => w.k8s.restoreCheckMark(pass))).rejects.toThrow("database/pg가 없다");
    expect(calls().writes).toEqual([]);
  });
});
