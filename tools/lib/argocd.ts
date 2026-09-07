// ArgoCD Application status 리더 — 변이 엔진(mutation.ts 수렴 판정)과 status 엔진(라이브 표시)이
// 공유하는 **리비전 해석** 한 벌. 두 엔진이 각자 `status.sync.revision` 단수 필드만 읽던 사본을
// 이 리더로 흡수한다(homelab-cli-r2 티켓 01 — 앱 레인 --wait가 원리적으로 수렴하지 못하던 결함).
//
// 왜 단수 필드로는 부족한가: 앱 Application(<app>-prod)은 appset(platform/argocd/root/appset.yaml의
// `sources:` 3개)이 만드는 **멀티소스**이고, ArgoCD 컨트롤러는 멀티소스에서 `status.sync.revision`을
// 비운 채 `status.sync.revisions[]`만 채운다(upstream controller/state.go — 라이브 실측 2026-09-07:
// 멀티소스 argocd·cnpg-operator는 revision=None·revisions=[…], 단일소스 cnpg-data·cache-prod는
// revision만). db/cache 레인의 Application은 단일소스라 단수 필드가 맞고, 앱 레인은 복수형만 맞다.
//
// 해석 규칙 — 확정 하나 + 미확정 셋:
//   resolved — 후보(단수 revision, 없으면 revisions[] 전부)가 전부 git SHA 형상이고 dedupe 후 1개.
//              그 값이 계보(gh compare)·표면 blob ref의 기준이다. 앱 레인의 세 source는 같은 repo/main을
//              가리키므로 정상 상태에서 revisions[]는 같은 SHA 셋이다.
//   skew     — SHA 후보가 dedupe 후 2개 이상(소스 간 리비전 불일치 — refresh 중간의 과도 상태). 계보는
//              원소별로 잴 수 있으나 표면 ref를 **하나로 고를 수 없어** 그 사이클은 미확정이다.
//   non-sha  — 후보 중 git SHA가 아닌 항목이 있다(helm 차트 버전 — 라이브 argocd=10.0.1·
//              cert-manager=v1.20.3 실재). gh compare에 넣으면 안 되는 값이라 호출 없이 미확정으로 접는다.
//   none     — 후보 0(revision 빈 문자열 + revisions 부재/빈 배열). 미확정 — success로 접히지 않는다.
// ⚠️ 앱 레인 revisions[]의 원소 수(픽스처의 3)는 appset sources 수에서 **외삽**한 값이다 — 라이브 앱
//    Application이 0건이라 실측이 없다. 이 리더는 길이를 가정하지 않는다(어떤 길이든 규칙은 같다).
export const GIT_SHA_RE = /^[0-9a-f]{7,40}$/;

export type SyncRevision =
  | { kind: "resolved"; revision: string; revisions: string[] }
  | { kind: "skew"; revisions: string[] }
  | { kind: "non-sha"; revisions: string[] }
  | { kind: "none"; revisions: string[] };

// status = Application `.status` 오브젝트(부재 허용). revisions는 관측 원본(dedupe 전)을 그대로 실어
// 보고 행이 "어느 source가 낡았는지"를 보여 줄 수 있게 한다.
export function syncRevisionOf(status: Record<string, any> | undefined): SyncRevision {
  const sync = (status?.sync ?? {}) as Record<string, unknown>;
  const single = typeof sync.revision === "string" ? sync.revision.trim() : "";
  const plural = Array.isArray(sync.revisions)
    ? (sync.revisions as unknown[]).map((r) => String(r ?? "").trim()).filter((r) => r !== "")
    : [];
  const candidates = single !== "" ? [single] : plural;
  if (candidates.length === 0) return { kind: "none", revisions: [] };
  if (candidates.some((r) => !GIT_SHA_RE.test(r))) return { kind: "non-sha", revisions: candidates };
  const uniq = [...new Set(candidates)];
  if (uniq.length === 1) return { kind: "resolved", revision: uniq[0], revisions: candidates };
  return { kind: "skew", revisions: candidates };
}

// 보고 행 조각 — resolved면 `revision`, 아니면 관측 원본 `revisions`(none은 둘 다 없음 = 관측 0).
// mutation의 applications[] 행과 status의 live.argocd가 같은 모양을 쓴다(계약 mutationApp·statusResult).
export function revisionFields(rev: SyncRevision): { revision?: string; revisions?: string[] } {
  if (rev.kind === "resolved") return { revision: rev.revision };
  return rev.revisions.length > 0 ? { revisions: rev.revisions } : {};
}
