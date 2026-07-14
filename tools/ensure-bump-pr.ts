// bump PR 멱등 게이트 — 같은 bump에 대해 열린 PR을 하나만 유지한다(중복 PR 버그의 수정 seam).
//
// 배경(라이브 버그): bump-poll.yaml은 run마다 새 브랜치 `bump-poll/<app>-<RUN_ID>`로 PR을 연다.
// 플래너(poll-ghcr)는 "GHCR 최신 vs main의 배포 핀"만 보는데 PR이 머지되기 전엔 main이 여전히
// 옛 digest다 → 매 10분 주기가 같은 후보로 새 PR을 낸다(page sha-815abb…: 11분에 PR 3개,
// 1개만 머지되고 나머지는 충돌 잔류).
//
// 설계: 브랜치명을 **결정적**으로 만들고(`bump-poll/<app>-<tag>` — RUN_ID 제거: 같은 bump = 같은
// 브랜치), PR 생성 직전 writer 토큰으로 **자기 레포의 그 브랜치 PR만** 조회해 판정한다.
//   gh pr list --head "bump-poll/<app>-<tag>" --state open \
//     --json number,isCrossRepository,mergeStateStatus,author
//
// 신뢰 경계: 이 레포는 **공개**다. 포크(cross-repo) PR은 같은 브랜치명을 쓸 수 있고 아무나 연다 →
// 절대 신뢰하지 않는다. 신뢰하면 포크 PR 하나로 배포를 무기한 억제할 수 있다(억제 = 공격 표면).
// 신뢰하는 제안은 **동일-레포(isCrossRepository=false) + writer App 작성자**뿐이다.
//
// 판정표:
//   열린 PR 없음 / 포크 PR만 / 동일-레포지만 writer 아님   → create  (신뢰할 제안이 없다)
//   신뢰 PR + 정상 상태(CLEAN/BEHIND/BLOCKED/UNKNOWN 등)   → skip    (이미 진행 중)
//   신뢰 PR + DIRTY(충돌)                                  → rebuild (최신 main에서 브랜치 재구축 → force-push)
// DIRTY를 rebuild로 되살리지 않으면 유일한 PR이 충돌난 순간 이후 폴링이 영원히 skip →
// 깨끗한 대체 PR이 영영 안 생겨 배포가 조용히 멈춘다(pr-sweeper는 DIRTY를 안 건드린다).
//
// ⚠️ 현재는 **red-capture 상태**다 — 판정 로직은 아직 없고 항상 "create"를 반환한다(= 버그 재현).
// 입력 사실은 파싱·검증해 `observed`에 실어 배선이 살아 있음을 증명한다. 회귀 테스트
// (tools/tests/test_ensure-bump-pr.bats, test_tags=regression)가 이 RED를 고정한다.
import { readFileSync, existsSync } from "node:fs";
import path from "node:path";
import { TAG_RE } from "./lib/image-pin.ts";

const USAGE = `ensure-bump-pr — bump PR 멱등 게이트(같은 bump = 같은 브랜치 = PR 1개)
사용법: bun tools/ensure-bump-pr.ts --app <app> --tag <sha-tag> (--prs <file|-> | --fixtures <dir>)
  --app <app>       앱 이름(소문자/숫자/하이픈)
  --tag <tag>       후보 배포 핀 tag(sha-<7..40 hex>)
  --prs <file|->    \`gh pr list --head <branch> --state open --json number,isCrossRepository,mergeStateStatus,author\`
                    출력(원시 스키마). \`-\`는 stdin.
  --fixtures <dir>  테스트 픽스처 소스 — <dir>/<app>.prs.json (파일 부재 = 열린 PR 0건)
  --writer <slug>   신뢰하는 writer App slug(기본 ukyi-homelab-writer)
  --help, -h        이 도움말
출력(stdout): {"action":"create"|"skip"|"rebuild","pr":<n>?,"reason":"…","branch":"…","observed":{…}}`;

// 기본 writer App slug. gh는 App 작성자를 `app/<slug>`로, REST/GraphQL은 `<slug>[bot]`로 준다 →
// 아래 normalizeLogin이 두 표기를 모두 같은 slug로 정규화한다.
const DEFAULT_WRITER = "ukyi-homelab-writer";
const APP_RE = /^[a-z0-9-]+$/;

const args: { app?: string; tag?: string; prs?: string; fixtures?: string; writer: string } = { writer: DEFAULT_WRITER };
const argv = process.argv.slice(2);
if (argv.includes("--help") || argv.includes("-h")) { console.log(USAGE); process.exit(0); }
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === "--app") args.app = argv[++i];
  else if (a === "--tag") args.tag = argv[++i];
  else if (a === "--prs") args.prs = argv[++i];
  else if (a === "--fixtures") args.fixtures = argv[++i];
  else if (a === "--writer") args.writer = argv[++i];
  else {
    console.error(`알 수 없는 인자: ${a}`);
    process.exit(2);
  }
}

// 사용법 위반(인자)은 exit 2, 비신뢰 입력(PR JSON) 결함은 exit 1 — 둘 다 fail-closed(조용한 create 금지).
function usageError(msg: string): never {
  console.error(`ensure-bump-pr: ${msg}`);
  process.exit(2);
}
function inputError(msg: string): never {
  console.error(`ensure-bump-pr: 신뢰할 수 없는 PR 입력 — ${msg} (fail-closed: 판정하지 않는다)`);
  process.exit(1);
}

if (!args.app) usageError("--app 필수");
if (!args.tag) usageError("--tag 필수");
if (!APP_RE.test(args.app)) usageError(`--app 형식 위반: '${args.app}' (소문자/숫자/하이픈만)`);
if (!TAG_RE.test(args.tag)) usageError(`--tag 형식 위반: '${args.tag}' (sha-<7..40 hex>)`);
if (!args.prs && !args.fixtures) usageError("--prs 또는 --fixtures 중 하나 필수");

// 결정적 브랜치명 — 같은 bump는 항상 같은 브랜치로 수렴한다(RUN_ID 제거가 중복 PR의 핵심 픽스).
const branch = `bump-poll/${args.app}-${args.tag}`;

// gh pr list --json이 주는 원시 스키마. author는 봇일 때 {is_bot, login}만 오고(id/name 없음),
// 사람일 때 {id, is_bot, login, name}이 온다 → login/is_bot만 신뢰한다(라이브 확인 완료).
type RawPr = { number: number; isCrossRepository: boolean; mergeStateStatus: string; author: { login: string; is_bot?: boolean } };

function loadRaw(): string {
  if (args.prs) {
    if (args.prs === "-") return readFileSync(0, "utf8"); // stdin
    if (!existsSync(args.prs)) inputError(`--prs 파일 없음: ${args.prs}`);
    return readFileSync(args.prs, "utf8");
  }
  // 픽스처 레인(테스트 전용, poll-ghcr 규약과 동일): 파일 부재 = 열린 PR 0건.
  const p = path.join(args.fixtures!, `${args.app}.prs.json`);
  return existsSync(p) ? readFileSync(p, "utf8") : "[]";
}

// 비신뢰 입력 검증 — 빈 문자열/깨진 JSON/배열 아님/필드 누락·타입 위반은 전부 fail-closed.
// (조용히 create로 흘리면 "조회 실패 = 중복 PR"이 되어 버그가 그대로 재현된다.)
function parsePrs(raw: string): RawPr[] {
  if (raw.trim() === "") inputError("빈 입력");
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch (e) {
    inputError(`JSON 파싱 실패: ${(e as Error).message}`);
  }
  if (!Array.isArray(parsed)) inputError(`최상위가 배열이 아님(gh pr list --json은 배열)`);
  return parsed.map((pr: any, i: number): RawPr => {
    const at = `[${i}]`;
    if (pr === null || typeof pr !== "object") inputError(`${at} 객체가 아님`);
    if (!Number.isInteger(pr.number)) inputError(`${at}.number 정수 아님`);
    if (typeof pr.isCrossRepository !== "boolean") inputError(`${at}.isCrossRepository 불리언 아님`);
    if (typeof pr.mergeStateStatus !== "string" || pr.mergeStateStatus === "") inputError(`${at}.mergeStateStatus 문자열 아님`);
    if (pr.author === null || typeof pr.author !== "object") inputError(`${at}.author 객체가 아님`);
    if (typeof pr.author.login !== "string" || pr.author.login === "") inputError(`${at}.author.login 문자열 아님`);
    return {
      number: pr.number,
      isCrossRepository: pr.isCrossRepository,
      mergeStateStatus: pr.mergeStateStatus,
      author: { login: pr.author.login, is_bot: pr.author.is_bot },
    };
  });
}

// gh는 App 작성자를 `app/<slug>`로, REST/GraphQL은 `<slug>[bot]`로 표기한다 — 둘 다 같은 slug로 정규화.
// (라이브 확인: `gh pr list --json author` → {"login":"app/ukyi-homelab-writer","is_bot":true})
function normalizeLogin(login: string): string {
  return login.replace(/^app\//, "").replace(/\[bot\]$/, "").toLowerCase();
}

// 신뢰하는 제안 = 동일-레포(포크 아님) + writer App 작성자. 그 외(포크·타인)는 사실로만 관측하고
// 판정 근거로 쓰지 않는다 — 억제(suppression)에 악용될 수 있는 표면이기 때문.
function isTrusted(pr: RawPr, writer: string): boolean {
  if (pr.isCrossRepository) return false;
  return normalizeLogin(pr.author.login) === normalizeLogin(writer);
}

const prs = parsePrs(loadRaw());
const observedPrs = prs.map((pr) => ({ ...pr, trusted: isTrusted(pr, args.writer) }));
const trusted = observedPrs.find((pr) => pr.trusted) ?? null;

// ⚠️ red-capture: 여기가 수정 seam이다. 지금은 판정을 버그 상태로 고정한다 — 신뢰하는 열린 PR이
// 이미 있어도 무조건 "create"를 반환한다(= 매 주기 중복 PR). 관측한 사실은 observed에 싣는다.
// 수정 시 위 판정표대로 skip/rebuild를 반환하도록 이 블록만 바꾸면 된다.
const result = {
  action: "create" as const,
  reason: "red-capture: 판정 미구현 — 신뢰하는 열린 PR 유무와 무관하게 항상 create(중복 PR 버그 재현)",
  branch,
  observed: {
    prs: observedPrs,
    trusted: trusted ? { number: trusted.number, mergeStateStatus: trusted.mergeStateStatus } : null,
  },
};
console.log(JSON.stringify(result, null, 2));
