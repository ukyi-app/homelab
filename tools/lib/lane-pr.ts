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
import { LANES, fillLanePattern, isDispatchLaneBranch, type LaneAction } from "./catalog-rows.ts";
import { compact } from "./contract.ts";
import { ghRead, type GhRead } from "./exec.ts";
import { APP_NAME_RE, RESOURCE_NAME_RE } from "./identity.ts";
import { HOMELAB_REPO, OWNER } from "./platform.ts";

// state — 머지 관측 루프의 종결 축. merged_at만 보면 close(미머지)가 데드라인까지 '머지
// 대기'로 접힌다. 옵셔널인 이유: 이 필드를 모르는 픽스처·응답에서 undefined가 되고, 엄격 동등
// 비교라 무관 케이스를 뒤집지 않는다(state 부재 = 미판정, closed로 오독하지 않는다).
// head_sha — required check(gate) 조기 종결의 좌표. check-run은 커밋에 붙으므로 PR
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

// ── 열린 homelab PR 목록(레인 무관 스캔) ───────────────────────────────────────────────────
// 위 정확 조회와 축이 다르다: 저쪽은 "이 브랜치의 PR"이고 이쪽은 "지금 열려 있는 것 전부"다.
// 소비자 둘이 같은 질의·같은 투영을 공유한다 — status(머지 대기 레인 표시)와 변이 엔진의
// 중복 디스패치 preflight. 사본 둘이면 한쪽만 고쳐도 초록인 클래스라 여기 한 벌만 둔다.
//
// per_page 상한 — 도달하면 "더 있을 수 있다"가 **사실**이라 소비자가 그것을 말해야 한다
// (status는 truncated 필드로, preflight는 관측 부재로). 상한을 안 말하면 101번째 PR이 '없음'과
// 구별되지 않는다. 질의 문자열이 이 상수에서 나와야 판정과 질의가 함께 움직인다.
export const OPEN_PR_PAGE_MAX = 100;
export const OPEN_PR_JQ = "[.[] | {number, title, head: .head.ref, html_url, auto_merge: (.auto_merge != null)}]";
// 3상 리더를 그대로 돌려준다 — 극성(fail-loud / fail-open)과 사유 문구는 콜사이트 소유다.
// 두 소비자의 극성이 서로 다르므로(status의 app 모드는 fail-loud, preflight는 fail-open) 이
// 함수가 그것을 고르면 한쪽이 반드시 틀린다.
export function readOpenHomelabPrs(): GhRead {
  return ghRead(`repos/${HOMELAB_REPO}/pulls?state=open&per_page=${OPEN_PR_PAGE_MAX}`, OPEN_PR_JQ);
}

// 같은 레인·같은 키의 **열린** PR 판정 — 변이 엔진의 중복 디스패치 preflight가 쓰는 3상 관측.
// 판정 술어는 레인 신원 행이 소유하는 `isDispatchLaneBranch` 하나다(status.ts:67·:273과 같은
// 술어 — 여기서 접두를 리터럴로 복제하면 그게 브랜치 문법의 두 번째 진실이다).
// 3상인 이유: hit(중복 실재)·clear(없음)·blind(관측 부재)를 둘로 접으면 GitHub 계층 blip 한 번이
// 'clear'로(경고가 조용히 죽는다) 또는 'hit'으로(정당한 변이가 막힌다) 위장한다. 어느 쪽으로
// 접을지는 콜사이트가 명시적으로 고른다.
// ⚠️ 절단(상한 도달)은 clear가 아니라 blind다 — 페이지네이션을 더하는 대신 "다음 페이지 유무를
//    모른다"를 그대로 낸다(형제 판단: mutation.ts CHECK_RUNS_PER_PAGE 절). 단 **페이지 안에서
//    이미 찾았으면 hit이 먼저다** — 찾은 것은 절단과 무관한 사실이고, 순서가 뒤집히면 꽉 찬
//    페이지에서 검출이 통째로 죽는다.
// ⚠️ 응답이 배열이 아니면(jq 투영 드리프트·형상 변경) 그것도 관측 부재다 — `?? []`로 접으면
//    '열린 PR 0건'과 구별되지 않는다(조용한 clear는 이 관측의 유일한 무증인 출구다).
export type OpenLanePr = { number: number; url: string; head: string };
export type OpenLaneConflict =
  | { kind: "hit"; pr: OpenLanePr }
  | { kind: "clear" }
  | { kind: "blind"; reason: string };
export function openLaneConflict(branchPattern: string, key: string): OpenLaneConflict {
  const g = readOpenHomelabPrs();
  if (g.kind !== "ok") return { kind: "blind", reason: g.reason };
  if (!Array.isArray(g.value)) return { kind: "blind", reason: "열린 PR 응답이 배열이 아니다(jq 투영/응답 형상 확인)" };
  const rows = g.value as Array<Record<string, unknown>>;
  for (const p of rows) {
    if (!isDispatchLaneBranch(branchPattern, key, String(p.head))) continue;
    return { kind: "hit", pr: { number: Number(p.number), url: String(p.html_url), head: String(p.head) } };
  }
  if (rows.length >= OPEN_PR_PAGE_MAX) {
    return { kind: "blind", reason: `열린 PR 목록이 상한(${OPEN_PR_PAGE_MAX}건)에 닿아 꼬리 미관측 — 다음 페이지 유무 미상` };
  }
  return { kind: "clear" };
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
