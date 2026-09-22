// AIOps 관측 출처 커널 단위 회귀 — 출처/제안 축 분리와 형식 fail-closed.
// (통합 회귀는 같은 디렉토리의 test_aiops-provenance.bats — 실제 임시 Git 저장소.)
import { describe, expect, test } from "bun:test";
import { readProvenance, requireRevision } from "../lib/aiops-provenance.ts";

const SHA_A = "a".repeat(40);
const SHA_B = "b".repeat(40);

describe("readProvenance", () => {
  test("captured source alone is the revision and no proposal axis is invented", () => {
    const provenance = readProvenance({ AIOPS_SOURCE_REVISION: SHA_A });
    expect(provenance).toEqual({ sourceRevision: SHA_A });
    expect("proposalRevision" in provenance).toBe(false);
  });

  test("proposal commit stays a separate field from the captured source", () => {
    expect(readProvenance({ AIOPS_SOURCE_REVISION: SHA_A, AIOPS_PROPOSAL_REVISION: SHA_B }))
      .toEqual({ sourceRevision: SHA_A, proposalRevision: SHA_B });
  });

  test("a missing or empty source revision fails closed", () => {
    expect(() => readProvenance({})).toThrow("source-revision-required");
    expect(() => readProvenance({ AIOPS_SOURCE_REVISION: "" })).toThrow("source-revision-required");
  });

  test("a malformed source revision fails closed", () => {
    for (const bad of [SHA_A.slice(0, 39), SHA_A + "a", SHA_A.toUpperCase(), "g".repeat(40), `${SHA_A}\n`, " not-a-sha "]) {
      expect(() => readProvenance({ AIOPS_SOURCE_REVISION: bad })).toThrow("source-revision-invalid");
    }
  });

  test("a malformed proposal revision fails closed instead of shipping misleading metadata", () => {
    expect(() => readProvenance({ AIOPS_SOURCE_REVISION: SHA_A, AIOPS_PROPOSAL_REVISION: "nope" }))
      .toThrow("proposal-revision-invalid");
  });

  test("a proposal equal to the source is a wiring bug, not two axes", () => {
    expect(() => readProvenance({ AIOPS_SOURCE_REVISION: SHA_A, AIOPS_PROPOSAL_REVISION: SHA_A }))
      .toThrow("proposal-revision-equals-source");
  });
});

describe("requireRevision", () => {
  test("passes a canonical 40-hex revision through untouched", () => {
    expect(requireRevision(SHA_B, "unused")).toBe(SHA_B);
  });

  test("rejects a trailing newline even though the regex anchors would allow it", () => {
    expect(() => requireRevision(`${SHA_B}\n`, "code")).toThrow("code");
  });
});
