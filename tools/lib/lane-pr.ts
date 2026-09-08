// 레인 브랜치 PR의 **좌표**와 그 정확 조회 — 변이 엔진(자기 PR 특정)과 status(`--branch` 재개
// 조회)가 같은 질의·같은 투영·같은 파싱을 공유한다(사본 둘이면 한쪽만 고쳐도 초록인 클래스).
//
// 왜 '정확 조회'인가: `pulls?state=all&head=<owner>:<branch>`의 head는 **정확 일치**라 형제
// 브랜치(`…/mydb-5011`)가 `…/mydb-501` 조회 응답에 원리적으로 섞이지 않는다. 와일드카드 스캔·
// correlation 순회는 이 모듈의 축이 아니다(그 둘은 오귀속과 예산을 함께 들여온다).
//
// ⚠️ 브랜치 문법의 SSOT는 레인 신원 행(catalog-rows LANES.branchPattern)이다 — 여기서 접두를
// 리터럴로 복제하지 않는다. 행이 순수 기술자(import 0)라 gh 질의·이름 정책을 가질 수 없어서,
// '행에서 파생한 파싱 + 질의'가 이 모듈에 산다.
import { LANES, fillLanePattern, type LaneAction } from "./catalog-rows.ts";
import { compact } from "./contract.ts";
import { ghRead, type GhRead } from "./exec.ts";
import { APP_NAME_RE, RESOURCE_NAME_RE } from "./identity.ts";
import { HOMELAB_REPO, OWNER } from "./platform.ts";

// state — 머지 관측 루프의 종결 축(티켓 05). merged_at만 보면 close(미머지)가 데드라인까지 '머지
// 대기'로 접힌다. 옵셔널인 이유: 이 필드를 모르는 픽스처·응답에서 undefined가 되고, 엄격 동등
// 비교라 무관 케이스를 뒤집지 않는다(state 부재 = 미판정, closed로 오독하지 않는다).
// head_sha — required check(gate) 조기 종결의 좌표(티켓 47). check-run은 커밋에 붙으므로 PR
// 번호가 아니라 **head SHA**가 질의 축이다. state와 같은 이유로 옵셔널이다: 이 필드를 모르는
// 픽스처·응답에서 undefined가 되고, 소비자(mutation.ts)는 부재를 fail-open으로 접는다.
// ⚠️ 응답의 중첩(`head.sha`)은 투영이 편다 — 이 행 타입은 이미 평탄한 형상이다.
export type LanePrRow = { number: number; html_url: string; merged_at: string | null; merge_commit_sha: string | null; state?: string; head_sha?: string };

// 투영 SSOT — 목록형과 단건형이 같은 필드 집합을 쓴다(단건 권위 조회는 mutation.ts 소유).
// 이 문자열은 argv 원장에 그대로 실려 테스트가 핀한다 — 필드가 빠지면 판정이 조용히 죽는다.
export const LANE_PR_FIELDS = "{number, html_url, merged_at, merge_commit_sha, state, head_sha: .head.sha}";
export const LANE_PR_JQ = `[.[] | ${LANE_PR_FIELDS}]`;

// head의 owner는 platform.ts의 OWNER SSOT다 — 여기서 HOMELAB_REPO를 다시 split하면 파생 지점이
// 갈린다(platform.ts:6 주석이 금지한 형태 · test_platform.bats의 파생 가드가 강제).
export function lanePrPath(branch: string): string {
  return `repos/${HOMELAB_REPO}/pulls?state=all&head=${OWNER}:${branch}`;
}

// 3상 리더 — 값과 실패 사유를 함께 준다(머지 루프가 사유를 pendingReason 접미로 싣는다).
export function readLanePrs(branch: string): GhRead {
  return ghRead(lanePrPath(branch), LANE_PR_JQ);
}

// 결과 계약의 PR 핸들 형상(mutationPr) — 변이 엔진과 status --branch가 같은 모양을 낸다.
export function lanePrRef(pr: LanePrRow): Record<string, unknown> {
  return compact({ number: pr.number, url: pr.html_url, merged: pr.merged_at !== null, mergeSha: pr.merge_commit_sha ?? undefined });
}

// 브랜치 → (레인, 키, run id) 복원. 생성 방향(laneMutationFields.branchFor)의 역이고, 판정은
// **왕복 등식**으로 확증한다: 복원한 셋을 행 패턴에 다시 채워 원문과 같아야 한다. 접두만 보는
// 판정은 하이픈 이름에서 형제를 오귀속하므로(page ↔ page-extra) tail 형식(`-<runId>`, \d+)까지가
// 판정이고, 키는 그 레인의 이름 정책(app=APP_NAME_RE / resource=RESOURCE_NAME_RE)을 통과해야 한다
// — 그래야 임의 ref(`../x`·`refs/heads/x`)가 gh 질의 문자열로 새지 않는다.
export function parseLaneBranch(head: string): { action: LaneAction; key: string; runId: number } | null {
  for (const row of Object.values(LANES)) {
    const parts = row.branchPattern.split("{key}");
    if (parts.length !== 2 || !parts[1]!.endsWith("{runId}")) continue; // 행 문법이 이 파싱의 형태가 아니다
    const prefix = parts[0]!;
    const mid = parts[1]!.slice(0, parts[1]!.length - "{runId}".length);
    if (mid === "" || !head.startsWith(prefix)) continue;
    const body = head.slice(prefix.length);
    const cut = body.lastIndexOf(mid);
    if (cut <= 0) continue;
    const key = body.slice(0, cut);
    const tail = body.slice(cut + mid.length);
    if (!/^\d+$/.test(tail)) continue;
    if (!(row.keyKind === "app" ? APP_NAME_RE : RESOURCE_NAME_RE).test(key)) continue;
    if (fillLanePattern(row.branchPattern, { key, runId: tail }) !== head) continue; // 왕복 등식
    return { action: row.action, key, runId: Number(tail) };
  }
  return null;
}

// 입력 술어 — CLI(usage 오류 exit 2)·MCP(invalid params)가 공유한다. 레인 접두 집합은 행에서
// 파생해 사유에 싣는다(운영자가 무엇이 허용인지 보고 고칠 수 있게).
export function laneBranchInputError(branch: string): string | null {
  if (parseLaneBranch(branch) === null) {
    const prefixes = Object.values(LANES).map((r) => r.branchPattern.split("{key}")[0]!).join(" | ");
    return `브랜치 형식 불량(디스패처 레인 접두 [${prefixes}] + <key>-<runId>): ${branch}`;
  }
  return null;
}
