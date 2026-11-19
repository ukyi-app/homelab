// 올리브 대상 목록. 실행 파일에 들어간 목록이 저장소의 platform/olive/targets.yaml과 같은지 파일을 직접 읽어 대조한다.
import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { oliveTargets, parseOliveTargets } from "../../src/core/olive-targets";

const FILE = join(import.meta.dir, "..", "..", "..", "platform", "olive", "targets.yaml");
const good = { id: "a", kind: "executor", namespace: "ns-a", deployment: "dep", declaredBy: "", stop: true, start: false };

describe("올리브 대상 목록", () => {
  test("저장소의 targets.yaml과 칸까지 같다", () => {
    const raw = Bun.YAML.parse(readFileSync(FILE, "utf8")) as { targets: unknown[] };
    expect(oliveTargets()).toEqual(raw.targets as any);
    expect(oliveTargets().length).toBeGreaterThan(0);
  });

  test("꼴이 다르면 빈 목록으로 넘어가지 않고 던진다", () => {
    const bad: unknown[] = [null, {}, { targets: [] }, { targets: "x" }, { targets: [{ ...good, stop: "true" }] }, { targets: [{ ...good, namespace: "Bad_NS" }] }, { targets: [{ ...good, deployment: undefined }] }, { targets: [good, good] }];
    for (const raw of bad) expect(() => parseOliveTargets(raw)).toThrow("올리브 대상");
  });
});
