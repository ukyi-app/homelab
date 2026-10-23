// 시험 사이 추적 상태 격리(#873 CI 실패의 회귀 시험). 같은 파일 안의 시험은 적힌 순서대로 돈다.
// 앞 시험이 만든 가짜 시크릿("a" 16자)이 뒤 시험의 가짜 SHA("a" 40자) argv를 시크릿으로 오인하게 하면 안 된다.
// 이 시험은 루트 bunfig.toml의 preload(cli/test/setup.ts)가 시험마다 추적 목록을 비울 때만 통과한다.
import { describe, expect, test } from "bun:test";
import { HOMELAB_REPO } from "../../src/core/github";
import { Secret, containsTracked } from "../../src/core/secret";
import { FAKE_SHA, ghGet, testCtx } from "../harness";

describe("추적 상태 격리", () => {
  test("앞 시험: 가짜 SHA와 겹치는 값을 추적에 올린다", () => {
    new Secret("a".repeat(16));
    expect(containsTracked(FAKE_SHA)).toBe(true);
  });

  test("뒤 시험: 앞 시험의 추적이 남지 않아 가짜 SHA로 저장소 파일을 읽는다", () => {
    expect(containsTracked(FAKE_SHA)).toBe(false);
    const path = `repos/${HOMELAB_REPO}/contents/apps/smoke/values.yaml?ref=${FAKE_SHA}`;
    const { ctx, calls } = testCtx("plan", [ghGet(path, 404, {})]);
    expect(ctx.repo.readFile("apps/smoke/values.yaml", FAKE_SHA)).toBeNull();
    expect(calls().calls.length).toBe(1);
  });
});
