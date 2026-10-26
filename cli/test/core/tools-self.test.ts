// doctor의 PATH homelab 확인(T12-05 운영: 옛 bun link ~/.bun/bin/homelab이 새 CLI를 가렸다). 링크를 따라간 실제 파일로 비교한다.
import { describe, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { toolsRead } from "../../src/core/tools";
import { testRoot } from "../harness";

const noExec = () => {
  throw new Error("selfOnPath는 외부 명령을 부르지 않는다");
};

function layout() {
  const top = mkdtempSync(join(testRoot(), "self-"));
  const a = join(top, "a");
  const b = join(top, "b");
  mkdirSync(a);
  mkdirSync(b);
  const running = join(top, "main.ts");
  const other = join(top, "old-homelab.ts");
  for (const f of [running, other]) {
    writeFileSync(f, "#!/bin/sh\n");
    chmodSync(f, 0o755);
  }
  return { top, a, b, running, other };
}

describe("tools.selfOnPath", () => {
  test("PATH의 첫 homelab이 지금 실행 파일로 가는 링크면 같다", () => {
    const l = layout();
    symlinkSync(l.running, join(l.a, "homelab"));
    const s = toolsRead(noExec as any, { PATH: `${l.a}:${l.b}` }, l.running).selfOnPath();
    expect(s).toEqual({ first: join(l.a, "homelab"), running: l.running, same: true });
  });

  test("앞의 옛 링크가 가리면 다르다(뒤에 맞는 것이 있어도 첫 것만 본다)", () => {
    const l = layout();
    symlinkSync(l.other, join(l.a, "homelab"));
    symlinkSync(l.running, join(l.b, "homelab"));
    const s = toolsRead(noExec as any, { PATH: `${l.a}:${l.b}` }, l.running).selfOnPath();
    expect([s.first, s.same]).toEqual([join(l.a, "homelab"), false]);
  });

  test("PATH에 없으면 first null, PATH 자체가 없어도 던지지 않는다", () => {
    const l = layout();
    expect(toolsRead(noExec as any, { PATH: l.a }, l.running).selfOnPath()).toEqual({ first: null, running: l.running, same: false });
    expect(toolsRead(noExec as any, {}, l.running).selfOnPath().first).toBeNull();
  });
});
