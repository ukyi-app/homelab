// AIOps 관측 출처 커널 — 검사 코드의 출처(source revision)와 실행·제안 축을 분리한다.
//
// 관측 artifact의 `revision`은 **checkout 직후 캡처한 검사 코드 출처**만 담는다
// (GHA에서는 `.github/actions/aiops-provenance`가 캡처해 넘긴다). 실행 중 pr-first-commit이
// 만든 제안 커밋은 출처가 아니며, `proposalRevision` 별도 필드로만 나간다. 실행 HEAD(GITHUB_SHA)는
// collector가 run 객체와 대조하는 별개 축이라 여기서 다루지 않는다.
//
// main 도달성(수집 계약 `artifact-revision-not-trusted-main`)은 collector가 API compare로 판정한다 —
// 이 커널은 형식·필수 여부만 fail-closed로 강제하고 네트워크를 모른다.
export const REVISION_RE = /^[a-f0-9]{40}$/;

export interface Provenance {
  /** 관측 revision으로 실린다 — 검사 코드의 신뢰 출처 SHA. */
  sourceRevision: string;
  /** 실행이 만든 제안 커밋 SHA(있으면) — revision과 다른 필드로만 소비된다. */
  proposalRevision?: string;
}

export function requireRevision(value: string, code: string): string {
  // `$`는 JS에서 끝의 개행 앞에도 매치한다 — 길이를 함께 재서 trailing newline을 거부한다.
  if (!REVISION_RE.test(value) || value.length !== 40) throw new Error(code);
  return value;
}

export function readProvenance(env: Record<string, string | undefined>): Provenance {
  const source = env.AIOPS_SOURCE_REVISION ?? "";
  if (source === "") throw new Error("source-revision-required");
  const sourceRevision = requireRevision(source, "source-revision-invalid");
  const proposal = env.AIOPS_PROPOSAL_REVISION ?? "";
  if (proposal === "") return { sourceRevision };
  const proposalRevision = requireRevision(proposal, "proposal-revision-invalid");
  // 커밋 없이 제안 필드가 채워졌다는 뜻이다(배선 오류) — 동일 SHA를 두 축으로 오표기하지 않는다.
  if (proposalRevision === sourceRevision) throw new Error("proposal-revision-equals-source");
  return { sourceRevision, proposalRevision };
}
