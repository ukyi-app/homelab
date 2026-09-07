// 공유 변이 엔진 — 변이 동사(db/cache create, app create/secrets/teardown)의 공통 골격.
//   correlation nonce 생성 → 디스패치(gh workflow run) → nonce 에코 run-name으로 자기 run 특정
//   (정확히 1개만 채택: ≥2 = race fail-closed, 0 = 재조회 후 pending — 관측 차분은 신원
//   메커니즘이 아니다, 스펙 run 특정 절) → run conclusion 추적(실패 시 실패 잡 열거 + run URL)
//   → run_id 브랜치로 PR 특정(3상: found/empty/error — empty·error는 deadline 독립 grace 재조회 뒤 판정,
//   noopForbidden이면 0건은 no-op이 아니라 fail-loud) → [--wait] 머지 관측(자동/수동 레인 — 머지 없이
//   닫힌 PR은 대기가 아니라 종결 관측이다: 단건 권위 조회로 확증한 뒤 failure) → 명명된
//   Application 집합 전체 수렴.
// 수렴 판정(스펙 대기 매트릭스): 관측 sync revision이 머지 SHA와 동일하거나 그 후손(gh compare —
//   로컬 git 이력 무의존) AND Synced AND Healthy AND 관측 리비전에서 desired-state 표면 실존.
//   관측 리비전의 해석은 lib/argocd.ts 공유 리더다 — 앱 레인 Application은 멀티소스라 단수 필드가
//   비고 `revisions[]`만 채워진다(resolved/skew/non-sha/none 4상 — status 엔진과 같은 리더).
//   health 단독 판정 금지(stale-Healthy: 이전 리비전 Healthy+OutOfSync에서 성공 오판).
//   표면 술어(스펙: "존재·내용이 여전히 요청값"): 관측 리비전의 blob sha == 머지 SHA 시점의
//   blob sha — 제거형·변경형 추월을 모두 superseded로 포착한다(전제 상태 변동 — exit 3 계열).
//   3상 판정: found/absent(HTTP 404 확정)/error(전송 오류) — 전송 오류는 추월의 증거가 아니라
//   그 사이클 미확정이다(일시 실패 한 번이 exit 3 종결이 되면 안 된다).
//   absence 수렴(teardown)의 표면 축은 두 ref를 본다 — 머지 SHA에서 부재 AND 철거 전 ref(first
//   parent)에서 실재. 부재 한 축만 보면 404의 모든 사유가 "철거 완료"와 같은 값이 된다.
// 진행 표시: 단계 전이마다 이벤트만 낸다(MutationOpts.onProgress — 문구·싱크는 셸 소유, MCP 미주입).
// KUBECONFIG 부재: 머지까지 확인하고 라이브 구간은 omitted=["live"]로 명시(생략 ≠ 성공 은폐).
// 시간 심: pollMs·deadlineMs 주입(테스트가 밀리초로 돌린다), nonce는 HOMELAB_CORRELATION 주입.
import { randomBytes } from "node:crypto";
import { revisionFields, syncRevisionOf } from "./argocd.ts";
import { compact } from "./contract.ts";
import { ghJson, ghRead, sh, type GhRead } from "./exec.ts";
import { CORRELATION_RE } from "./identity.ts";
import { LANE_PR_FIELDS, lanePrRef, readLanePrs, type LanePrRow } from "./lane-pr.ts";
import { HOMELAB_REPO } from "./platform.ts";

export type MutationSpec = {
  action: string;                                  // 예: "create-database"
  workflow: string;                                // 디스패처 파일명(예: create-database.yaml)
  dispatchInputs: Array<[string, string]>;         // -f k=v 순서 보존(argv 원장 계약 — correlation은 엔진이 뒤에 붙임)
  branchFor: (runId: number) => string;            // PR 브랜치 명명(레인 신원 행 파생 — catalog-rows)
  applications: Array<{ name: string; surfacePath: string }>; // --wait 수렴 대상 집합 + 표면
  resultBase: Record<string, unknown>;             // 모든 variant에 실리는 공통 필드({action, name, …})
  // 수동 머지 동사(create-app: 머지 = 공개 승인 · teardown-app: 머지 = 파괴 승인 — 둘 다
  // auto-merge:false). --wait의 미머지 pending은 실패가 아니라 설계된 바운디드 결과라 문구가
  // 다르고, 머지가 무엇을 승인하는지는 동사가 안다(approval). 엔진은 어떤 경로로도 auto-merge를
  // 켜지 않는다(원장에 gh pr 계열 argv가 아예 없다 — 테스트가 단언).
  manualMerge?: { approval: string };
  // 종결 술어. presence(기본): 명명된 Application 집합이 수렴(후손 리비전 + Synced + Healthy +
  // 표면이 요청값)해야 성공. absence(teardown-app): 삭제 대상은 Healthy가 될 수 없다 — 성공 =
  // Application 부재(appset finalizer cascade prune 완료)이고, 표면 술어의 극성도 함께 뒤집힌다
  // (철거 머지는 표면을 제거하므로 머지 SHA에서 표면이 사라져 있어야 요청이 반영된 것).
  // absence의 표면 축은 **두 ref 관측**이다 — 머지 SHA에서 부재 AND 철거 전 ref(머지 커밋의 first
  // parent)에서 실재. 후자가 없으면 404의 모든 사유가 "철거 완료"로 접힌다(무판정 통과).
  converge?: "presence" | "absence";
  // run 성공 + 브랜치 PR 0 = 정당한 no-op(update-secrets: 동일 봉인본 — pr-first-commit 멱등).
  // --wait 검증은 머지 SHA 없이 "관측 리비전의 표면 blob == homelab main의 표면 blob"으로 대체한다
  // (디스패처가 main HEAD와 비교한 그 기준). 미설정이면 PR 0은 명명 드리프트로 failure.
  noopOnMissingPr?: boolean;
  // no-op 금지 교차 증인(티켓 04): 콜사이트가 "이 실행은 반드시 PR을 만든다"를 아는 경우(app secrets
  // chain이 push했으면 kubeseal 비결정 암호문 = 바이트 변경 = 반드시 PR) true로 넘긴다. 그러면 PR 0은
  // no-op이 아니라 fail-loud다 — 낡은/빈 PR 스냅샷 한 번이 "이미 배선됨" exit 0으로 위장하는 것을 막는다.
  // 엔진은 chain 스키마를 모른다 — secrets.ts가 계산해 이 명시 필드로 넘긴다(resultBase를 들여다보지 않는다).
  noopForbidden?: boolean;
};

// PR 특정의 grace 재시도 횟수 — **deadline(endAt)과 독립한** 고정 소수. null(전송 오류)·0건은 미확정이라
// 이 횟수만큼 pollMs 간격으로 재조회한 뒤에만 판정한다(함정 「GitHub API는 낡은 스냅샷을 200으로 돌려준다」
// — 목록 endpoint는 read-replica라 방금 만든 PR이 빈 응답 한 번으로 올 수 있다). endAt에 매달면 step 3가
// 예산을 다 쓴 경우 재시도 0회 = 오늘과 같은 즉결(vacuous fix)이라 일부러 분리했다. 비용: 정당한 no-op
// (--no-seal·dispatch-only 동일 봉인본)은 매번 PR_GRACE_RETRIES × pollMs(기본 3 × 5s = 15s)만큼 느려진다.
// 테스트가 정확 count(1 + 3)로 이 상수를 핀한다(test_homelab-db.bats·test_homelab-secrets.bats).
export const PR_GRACE_RETRIES = 3;

// 디스패치 호출의 타임아웃 주입 심(**테스트 전용**) — 실물 경로는 seam 기본(exec.ts 30s)을 쓴다.
// 이름 규약은 형제 심과 같다(HOMELAB_TEST_ 접두 — exec.ts ALLOW_PUSH_REWRITE_ENV). 이 심이 없으면
// '디스패치 타임아웃' 분기는 hermetic 하네스에서 도달 불가라 무증인이 된다(seam에 시간 주입 축이
// 콜사이트 인자뿐이기 때문). 값이 정수·양수가 아니면 무시한다 — Number("")는 0이고 Number("x")는
// NaN이라, 둘 다 조용히 '무제한(0)'이나 NaN 타임아웃으로 새지 않게 양쪽을 다 막는다.
export const DISPATCH_TIMEOUT_ENV = "HOMELAB_TEST_DISPATCH_TIMEOUT_MS";

// 진행 이벤트(티켓 07) — 엔진은 **이벤트만** 낸다. 문구·싱크는 셸(homelab.ts)이 소유하고 MCP는
// 주입하지 않는다(stdio JSON-RPC 스트림 무오염). op가 Envelope만 반환한다는 원칙은 그대로다:
// 이벤트는 결과가 아니라 **진행 관측**이고 결과 계약(cli-result-schema.json)에 아무것도 더하지 않는다.
// 왜 필요한가: --wait는 최대 deadline 동안 Bun.sleepSync로 동기 블로킹인데 그 사이 stderr가 0줄이라,
// ^C·타임아웃 킬로 죽으면 correlation·run URL·PR URL이 어디에도 남지 않는다(재조회 핸들 유실).
// 왜 엔진이 직접 stderr에 쓰지 않는가: 계약 경계(표현은 셸 소유)가 흐려지고 hermetic bats의 argv
// 원장 표면이 탁해진다 — 주입 심이라야 MCP에서 "쓰지 않음"이 기본값으로 성립한다.
// ⚠️ 방출은 **단계 전이**에만 건다(폴링 하트비트는 별건). 그래서 사이클당 줄이 늘지 않는다.
export type ProgressStage = "dispatched" | "identified" | "concluded" | "pr" | "merged";
export type ProgressEvent = { stage: ProgressStage; correlation: string; runUrl?: string; prUrl?: string; sha?: string };

export type MutationOpts = { wait: boolean; pollMs: number; deadlineMs: number; identifyOnly: boolean; onProgress?: (e: ProgressEvent) => void };

// 대기 옵션 SSOT — 기본값과 검증 술어를 변이 동사 전부가 공유한다(콜사이트 인라인 사본 금지).
//
// deadlineMs = 20분의 분해와 출처(티켓 10 — **값은 바꾸지 않았다**, 재개 조건은 아래):
//   · required check `gate`(ci.yaml gate 잡): 잡 실행구간 p50 483s / p90 514s / max 532s ≈ 9분,
//     run 구간(큐 포함) max 1687s ≈ 28분 — ci.yaml:44-47이 기록한 2026-09-03 라이브 실측(완료 99건).
//   · 디스패처: 보조 잡 timeout-minutes 5(create-database.yaml:56) + 변이 본체 20(_create-database.yaml:27).
//   · homelab-mutation은 `queue: max` FIFO다 — bump-poll(10분 크론)·tf-reconcile(30분)·iac가 앞에
//     서면 그만큼이 순수 대기다.  · 머지 후 ArgoCD 수렴: timeout.reconciliation 30s(bootstrap-values.yaml:248).
//   합산 최선 ≈ 2 + 9 + 1 = 12분이고 큐 한 주기가 겹치면 20분에 맞닿는다. endAt은 디스패치 시점에
//   한 번 계산돼(아래 runMutation) run 출현·conclusion·머지·라이브 수렴이 이 예산 하나를 나눠 쓴다.
// 원칙: 클라이언트 데드라인이 자기가 관측하는 **서버측 천장**(ci.yaml `timeout-minutes: 45`)보다
//   짧으면 'CI가 아직 답을 안 냈다'가 'CLI가 확인하지 못함'으로 구조적으로 변환된다. 올린다면 45분이
//   방어 가능하고 30-40분은 감각값이다.
// ⚠️ 재개 조건 — 값 변경은 **첫 실전 `db create --wait`의 dispatch→merge 벽시계 실측** 뒤다(CLI 유래
//   run이 아직 0건이라 위 분해는 파이프라인 부품의 합이지 이 동사 자체의 실측이 아니다). 실측 없이
//   올리면 에이전트 foreground 상한(10분)과 사람의 인내를 둘 다 넘겨 pending이 더 늦게 돌아올 뿐이다.
//   pending은 실패가 아니라 설계된 바운디드 결과이고, 재개 경로는 재실행이 아니라 핸들 재조회다.
export const WAIT_DEFAULTS = { pollMs: 5_000, deadlineMs: 1_200_000 } as const;
// identifyOnly: run 식별 직후 run 핸들을 pending으로 반환하고 conclusion 추적(최대 deadline)을 건너뛴다.
// MCP 전용(release r1 a2=b3) — stdio 서버는 단일 스레드라 conclusion 폴링이 서버를 주어진 deadline
// (기본값을 물려받으면 WAIT_DEFAULTS.deadlineMs)만큼 블로킹한다.
// 스펙의 "결과의 run URL이 상관 핸들, 진행 확인은 status 핸들 조회로"를 실행형으로 만든다. CLI는 미설정.
// onProgress: 진행 이벤트 싱크(위 ProgressEvent 주석) — CLI 셸만 주입하고 MCP는 미설정이다.
export type WaitInput = { wait?: boolean; pollMs?: number; deadlineMs?: number; identifyOnly?: boolean; onProgress?: (e: ProgressEvent) => void };
export function waitInputError(input: WaitInput): string | null {
  if (input.pollMs !== undefined && !(Number.isInteger(input.pollMs) && input.pollMs > 0)) return `--poll-ms는 양의 정수여야 한다: ${input.pollMs}`;
  if (input.deadlineMs !== undefined && !(Number.isInteger(input.deadlineMs) && input.deadlineMs > 0)) return `--deadline-ms는 양의 정수여야 한다: ${input.deadlineMs}`;
  return null;
}
export function waitOpts(input: WaitInput): MutationOpts {
  return { wait: input.wait === true, pollMs: input.pollMs ?? WAIT_DEFAULTS.pollMs, deadlineMs: input.deadlineMs ?? WAIT_DEFAULTS.deadlineMs, identifyOnly: input.identifyOnly === true, onProgress: input.onProgress };
}
export type MutationOutcome = { variant: string; omitted: string[]; result: Record<string, unknown> };

function newNonce(): string {
  const injected = process.env.HOMELAB_CORRELATION;
  if (injected !== undefined) {
    if (!CORRELATION_RE.test(injected)) throw new Error(`HOMELAB_CORRELATION 형식 불량(CORRELATION_RE): ${injected}`);
    return injected;
  }
  return `hl-${Date.now().toString(36)}-${randomBytes(4).toString("hex")}`;
}

type RunRow = { id: number; name: string; status: string; conclusion: string | null; html_url: string };
// PR 행·투영·정확 조회는 lib/lane-pr.ts 공유(티켓 09) — status의 `--branch` 재조회가 같은 질의를
// 쓴다. state 축(티켓 05)의 근거도 그 모듈이 소유한다. 판정은 단건 권위 조회로 확증한 뒤에만 한다.
type PrRow = LanePrRow;

// 폴링 루프의 관측 실패 추적(티켓 06) — 마지막 실패 사유와 **연속** 실패 횟수를 들고 데드라인
// pendingReason의 접미를 만든다. 성공 관측이 한 번이라도 끼면 streak가 0으로 돌아가므로 접미는
// '지속 실패'에만 붙는다(한 사이클 blip을 원인으로 지목하지 않는다).
// ⚠️ 결과 필드는 신설하지 않는다 — mutationPending/teardownPending이 additionalProperties:false라
// 필드 추가는 생성기 2곳 + 골든 4개를 흔든다. 같은 파일의 absence 레인(:kubectlError)이 이미
// pendingReason 문자열 안에서 원인을 가른 선례다. **문구 SSOT는 이 헬퍼 하나**이고, 세 루프
// (run 특정·conclusion·머지)가 같은 접미를 쓴다(테스트가 리터럴 1건 + 콜사이트 3건으로 고정).
function pollWatch() {
  let reason = "";
  let streak = 0;
  return {
    observe: (g: GhRead): void => { if (g.kind === "ok") { streak = 0; } else { reason = g.reason; streak += 1; } },
    suffix: (): string => (streak === 0 ? "" : ` — 직전 GitHub 계층 조회 실패(${streak}회 연속): ${reason}`),
  };
}

export function runMutation(spec: MutationSpec, opts: MutationOpts): MutationOutcome {
  const correlation = newNonce();
  const base = { ...spec.resultBase, correlation };
  const endAt = Date.now() + opts.deadlineMs;
  const fail = (error: string, extra: Record<string, unknown> = {}): MutationOutcome =>
    ({ variant: "failure", omitted: [], result: compact({ ...base, ...extra, error }) });
  // 진행 이벤트 방출(티켓 07) — 싱크 미주입이면 no-op이다(MCP·라이브러리 소비자).
  const emit = (stage: ProgressStage, handles: { runUrl?: string; prUrl?: string; sha?: string } = {}): void => {
    opts.onProgress?.({ stage, correlation, ...handles });
  };

  // 1) 디스패치 — 유일한 변이 argv. correlation이 run-name에 에코된다(수령증).
  const dispatchArgs = ["workflow", "run", spec.workflow, "-R", HOMELAB_REPO];
  for (const [k, v] of spec.dispatchInputs) dispatchArgs.push("-f", `${k}=${v}`);
  dispatchArgs.push("-f", `correlation=${correlation}`);
  const injectedTimeout = Number(process.env[DISPATCH_TIMEOUT_ENV] ?? "");
  const dispatched = sh("gh", dispatchArgs, Number.isInteger(injectedTimeout) && injectedTimeout > 0 ? { timeoutMs: injectedTimeout } : {});
  // 타임아웃은 '실패'가 아니라 **결과 미상**이다(티켓 08) — 자식(gh)만 SIGTERM으로 죽었고 POST는
  // 서버에 이미 도달했을 수 있다(Bun 1.3.14 실측: ETIMEDOUT · status null · signal SIGTERM).
  // 여기서 fail하면 운영자·에이전트가 재실행하고, 그때 **새 nonce**가 발급돼 race 검출조차
  // 우회한 이중 run·PR 2개가 된다(`queue: max`는 직렬화지 dedupe가 아니다). 그래서 수령증
  // 메커니즘(2단계: nonce 에코 run 특정, 0건이면 pending)으로 그대로 넘긴다 — 재시도가 아니라
  // **관측**이다. ⚠️ 관용은 errKind timeout으로만 좁힌다: rc 비-0(인증 실패·입력 거부)은 지금처럼
  // 즉시 failure다(정말 안 나간 경우까지 pending으로 접으면 손해 방향이 뒤집힌다).
  const dispatchUnconfirmed = !dispatched.ok && dispatched.errKind === "timeout";
  if (!dispatched.ok && !dispatchUnconfirmed) return fail(`디스패치 실패 — ${dispatched.err.split("\n")[0] || "gh workflow run 비-0"}`);
  // correlation은 여기서부터 유효한 좌표다 — run이 아직 없어도 Actions에서 이 에코를 찾을 수 있다.
  emit("dispatched");

  // 2) 자기 run 특정 — run-name의 [nonce] 에코가 권위. 정확히 1개일 때만 채택.
  let run: RunRow | undefined;
  const identifyWatch = pollWatch();
  for (;;) {
    const got = ghRead(`repos/${HOMELAB_REPO}/actions/workflows/${spec.workflow}/runs?per_page=20`,
      "[.workflow_runs[] | {id, name, status, conclusion, html_url}]");
    identifyWatch.observe(got);
    if (got.kind === "ok") {
      const mine = (got.value as RunRow[]).filter((r) => r.name.includes(`[${correlation}]`));
      if (mine.length >= 2) {
        return { variant: "race", omitted: [], result: compact({ ...base, observedRuns: mine.length, error: `같은 correlation을 에코하는 run이 ${mine.length}개 — 신원 판정 불가(fail-closed)` }) };
      }
      if (mine.length === 1) { run = mine[0]; break; }
    }
    if (Date.now() >= endAt) {
      // 디스패치 응답이 유실된 경우(타임아웃)는 '접수됨'을 단언할 수 없다 — 그 사실과 함께,
      // 재실행이 아니라 Actions의 correlation 에코 확인이 다음 행동임을 문구가 지목한다(티켓 08).
      // ⚠️ 이 분기에는 run 핸들이 없다 — `status --run`도 `--branch`도 쓸 수 없다. 그래서 재개
      // 수단은 **실재하는 것**만 적는다(티켓 09): correlation을 받는 조회 동사는 없고(owner 결정
      // Q2 — `status --correlation` 핸들 모드는 열지 않는다: PR 본문에 correlation 에코가 없어
      // reusable 5벌 계약 변경이 선행이다), 유일하게 실재하는 확인 경로는 Actions에서 run-name의
      // [correlation] 에코를 눈으로 보는 것이다. 재디스패치는 새 nonce를 발급해 같은 이름의 PR
      // 두 개를 만든다 — 그래서 문구가 먼저 그것을 금지한다.
      const accepted = dispatchUnconfirmed
        ? "디스패치 응답이 타임아웃으로 유실됨(접수 여부 미상 — run이 이미 생성됐을 수 있다) · 재디스패치 금지 — Actions에서 run-name의 [correlation] 에코로 확인"
        : "run 미출현(디스패치는 접수됨) — 큐/크론 지연 가능 · 재디스패치 금지: Actions에서 run-name의 [correlation] 에코로 확인(run이 보이면 status --run <url>로 이어간다)";
      return { variant: "pending", omitted: [], result: compact({ ...base, pendingReason: `${accepted}${identifyWatch.suffix()}` }) };
    }
    Bun.sleepSync(opts.pollMs);
  }
  const runRef = () => compact({ id: run!.id, url: run!.html_url, conclusion: run!.conclusion ?? undefined });
  // 레인 브랜치는 run id의 순수 파생이다(추가 API 호출 0) — PR이 아직 없는 단계의 유일한 좌표.
  const branchOf = () => spec.branchFor(run!.id);
  emit("identified", { runUrl: run.html_url });

  // 2b) identifyOnly(MCP) — run을 식별했으면 conclusion 추적 없이 run 핸들을 pending으로 즉시 반환한다.
  // stdio 서버가 GitHub Actions run 완료(최대 deadline)까지 블로킹하지 않게 한다 — 진행은 status(run URL)
  // 재조회가 재개 경로다(스펙 "결과의 run URL이 상관 핸들, 진행 확인은 status 핸들 조회로", release r1 a2=b3).
  if (opts.identifyOnly) {
    // 좌표를 함께 싣는다(티켓 09): 이 분기에는 PR이 **원리적으로** 없고(run 완료 후 생긴다) run
    // 핸들만으로는 PR·머지로 갈 길이 없다. 브랜치는 run id의 순수 파생이라 조회가 0회 늘어난다 —
    // 소비자는 `homelab status --run <url> --branch <branch>`로 그 레인 PR을 정확 조회한다.
    return { variant: "pending", omitted: [], result: compact({ ...base, run: compact({ ...runRef(), branch: branchOf() }), pendingReason: "run 디스패치·식별 완료 — 진행은 status 핸들 조회로 확인: homelab status --run <run.url> --branch <run.branch>(동기 바운디드)" }) };
  }

  // 3) conclusion 추적 — queued/in_progress면 폴링, 실패면 실패 잡 열거.
  const concludeWatch = pollWatch();
  while (run.status !== "completed") {
    if (Date.now() >= endAt) {
      return { variant: "pending", omitted: [], result: compact({ ...base, run: runRef(), pendingReason: `run 진행 중 — 핸들(run URL)로 재조회 가능${concludeWatch.suffix()}` }) };
    }
    Bun.sleepSync(opts.pollMs);
    const got = ghRead(`repos/${HOMELAB_REPO}/actions/runs/${run.id}`, "{status, conclusion, html_url}");
    concludeWatch.observe(got);
    if (got.kind === "ok") run = { ...run, ...(got.value as Partial<RunRow>) };
  }
  emit("concluded", { runUrl: run.html_url });
  if (run.conclusion !== "success") {
    const jobs = ghJson(`repos/${HOMELAB_REPO}/actions/runs/${run.id}/jobs`,
      '[.jobs[] | select(.conclusion == "failure") | .name]');
    return fail(`run 실패(${run.conclusion})`, { run: compact({ ...runRef(), failedJobs: jobs ?? undefined }) });
  }

  // 4) PR 특정 — run_id 브랜치(reusable 명명 SSOT)로 권위 조회.
  const branch = branchOf();
  // 3상 리더(ghRead) — 머지 루프가 실패 사유를 pendingReason 접미로 실어야 하므로 값만 주는
  // ghJson 대신 사유를 함께 받는다. readPr은 그 축약(step 4 grace 루프는 사유를 쓰지 않는다).
  // 질의·투영은 lane-pr.ts 공유(status --branch가 같은 것을 쓴다).
  const readPrList = (): GhRead => readLanePrs(branch);
  const readPr = (): PrRow[] | null => { const g = readPrList(); return g.kind === "ok" ? (g.value as PrRow[]) : null; };
  // 단건 권위 조회 — 목록 endpoint는 read-replica 인덱스라 단건 리소스보다 낡을 수 있다(함정
  // 「GitHub API는 낡은 스냅샷을 200으로 돌려준다」). 종결(머지 없이 닫힘) 판정에만 쓴다.
  const readPrOne = (n: number): GhRead =>
    ghRead(`repos/${HOMELAB_REPO}/pulls/${n}`, LANE_PR_FIELDS);
  // 3상: found(≥1) / empty(0건) / error(null) — empty·error는 그 조회의 미확정이라 grace 재시도 뒤에만 판정.
  // 재시도는 endAt과 무관하다(PR_GRACE_RETRIES 주석) — 여기서 deadline을 보면 수정이 무효가 된다.
  let prs: PrRow[] | null = null;
  for (let attempt = 0; ; attempt++) {
    prs = readPr();
    if (prs !== null && prs.length > 0) break;
    if (attempt >= PR_GRACE_RETRIES) break;
    Bun.sleepSync(opts.pollMs);
  }
  if (prs === null) return fail(`PR 조회 실패 — GitHub 계층(grace 재시도 ${PR_GRACE_RETRIES}회 뒤에도 전송 오류)`, { run: runRef() });
  if (prs.length === 0 && spec.noopForbidden === true) {
    return fail(`run은 성공했으나 브랜치(${branch})의 PR이 없다 — 이 실행은 새 봉인본을 push했으므로 no-op일 수 없다(PR 목록 grace 재시도 ${PR_GRACE_RETRIES}회 뒤에도 0건: 낡은 스냅샷 또는 명명 드리프트 — fail-loud)`, { run: runRef() });
  }
  const noop = prs.length === 0 && spec.noopOnMissingPr === true;
  if (prs.length === 0 && !noop) return fail(`run은 성공했으나 브랜치(${branch})의 PR이 없다 — 명명 드리프트(no-op 동사가 아님)`, { run: runRef() });
  if (prs.length >= 2) {
    return { variant: "race", omitted: [], result: compact({ ...base, run: runRef(), observedRuns: prs.length, error: `브랜치 ${branch}에 PR이 ${prs.length}개 — 신원 판정 불가(fail-closed)` }) };
  }
  let pr: PrRow | undefined = noop ? undefined : prs[0];
  const prRef = () => (pr === undefined ? undefined : lanePrRef(pr));
  const doneVariant = noop ? "no-op" : "success";
  // no-op(PR 없음)에는 방출할 PR 핸들이 없다 — 없는 좌표를 지어내지 않는다.
  if (pr !== undefined) emit("pr", { runUrl: run.html_url, prUrl: pr.html_url });

  if (!opts.wait) {
    return { variant: doneVariant, omitted: [], result: compact({ ...base, waited: false, run: runRef(), pr: prRef() }) };
  }

  // 5) 머지 관측 — 자동 머지 동사는 required check(gate) 통과 후 auto-merge가, 수동 머지 동사
  // (manualMerge: create-app — 머지가 곧 공개 승인)는 사람이 머지한다. no-op은 머지가 없다.
  let mergeSha: string | undefined;
  if (pr !== undefined) {
    // 이 루프의 관측은 둘이다 — 목록 재조회와 종결 확증 조회. 둘 다 GitHub 계층 조회라 같은
    // watch가 센다(어느 쪽이 죽었든 운영자가 볼 것은 "이 대기는 관측이 안 되고 있다"이다).
    const mergeWatch = pollWatch();
    while (pr.merged_at === null) {
      // 종결 관측: 머지 없이 닫힘. 목록 인덱스가 단건 리소스보다 낡을 수 있으므로 단건 권위 조회로
      // 한 번 확증한 뒤에만 종결한다 — 확증이 ok가 아니면 미확정으로 두고 폴링을 계속한다(일시 실패
      // 한 번이 종결이 되면 안 된다, 3상 관측의 같은 규약). 확증이 머지를 보고하면 그 값으로 진행하고,
      // state가 open이면(reopen) 종결하지 않는다 — closed는 '거부'의 동의어가 아니다.
      if (pr.state === "closed") {
        const authoritative = readPrOne(pr.number);
        mergeWatch.observe(authoritative);
        if (authoritative.kind === "ok") {
          pr = { ...pr, ...(authoritative.value as PrRow) };
          if (pr.merged_at !== null) break;
          if (pr.state === "closed") {
            // 의도 추정 없는 관측 서술 — 무엇이 승인이었는지는 동사가 알고(manualMerge), 부가 문맥으로만 싣는다.
            const context = spec.manualMerge !== undefined ? ` · 이 동사의 머지가 곧 ${spec.manualMerge.approval}이었다` : "";
            return fail(`PR #${pr.number}이 머지 없이 닫혔다(state=closed, merged_at=null) — 변이 미반영(단건 권위 조회로 확증)${context}`,
              { run: runRef(), pr: prRef() });
          }
        }
      }
      if (Date.now() >= endAt) {
        const base5 = spec.manualMerge !== undefined
          ? `사람 머지 대기 — 머지가 곧 ${spec.manualMerge.approval}(PR 검토·머지 후 핸들로 재조회)`
          : "auto-merge 머지 미관측 — required check 대기 중일 수 있다(핸들로 재조회 가능)";
        return { variant: "pending", omitted: [], result: compact({ ...base, run: runRef(), pr: prRef(), pendingReason: `${base5}${mergeWatch.suffix()}` }) };
      }
      Bun.sleepSync(opts.pollMs);
      const again = readPrList();
      mergeWatch.observe(again);
      if (again.kind === "ok") {
        const rows = again.value as PrRow[];
        if (rows.length === 1) pr = rows[0];
      }
    }
    mergeSha = pr.merge_commit_sha ?? undefined;
    if (!mergeSha) return fail("머지는 관측됐으나 merge SHA가 비어 있다 — GitHub 응답 이상", { run: runRef(), pr: prRef() });
    emit("merged", { runUrl: run.html_url, prUrl: pr.html_url, sha: mergeSha });
  }
  // 요청값의 기준 ref — 머지 SHA(변이) 또는 main(no-op: 디스패처가 비교한 기준).
  const wantRef: string = mergeSha ?? "main";

  // 6) 라이브 수렴 — KUBECONFIG 부재는 생략(성공과 구분되는 명시 축), 집합 전체가 조건을 만족해야 성공.
  if ((process.env.KUBECONFIG ?? "") === "") {
    return { variant: doneVariant, omitted: ["live"], result: compact({ ...base, waited: true, run: runRef(), pr: prRef() }) };
  }
  // 표면 blob sha — found(sha)/absent(확정 404)/error(전송 오류 — 미확정) 3상. presence·absence 공용.
  type Blob = { kind: "found"; sha: string } | { kind: "absent" } | { kind: "error" };
  const blobAt = (ref: string, path: string): Blob => {
    const r = sh("gh", ["api", `repos/${HOMELAB_REPO}/contents/${path}?ref=${ref}`, "--jq", ".sha"]);
    if (r.ok) return { kind: "found", sha: r.out.trim() };
    return /\(HTTP 404\)/.test(r.err) ? { kind: "absent" } : { kind: "error" };
  };
  // ref 고정 blob 리더 — 확정 관측만 캐시(전송 오류는 미확정이라 재평가 여지를 남긴다).
  // 리더가 둘이다: 요청값(머지 SHA 시점)과 철거 전(머지 커밋의 first parent — absence 수렴 전용).
  const blobReader = (ref: string) => {
    const cache = new Map<string, Blob>();
    return (path: string): Blob => {
      const hit = cache.get(path);
      if (hit !== undefined) return hit;
      const b = blobAt(ref, path);
      if (b.kind !== "error") cache.set(path, b);
      return b;
    };
  };
  const requestedBlob = blobReader(wantRef);
  // 머지 커밋의 first parent = 머지 직전 main(merge/squash/rebase 어느 방식이든 첫 부모가 base다).
  // 확정 관측만 캐시 — 전송 오류는 null(미확정)이고 계보는 불변이라 성공 관측은 재조회하지 않는다.
  const parentCache = new Map<string, string>();
  const firstParentOf = (sha: string): string | null => {
    const hit = parentCache.get(sha);
    if (hit !== undefined) return hit;
    const r = sh("gh", ["api", `repos/${HOMELAB_REPO}/commits/${sha}`, "--jq", ".parents[0].sha"]);
    if (!r.ok) return null; // 전송 오류 — 미확정
    const p = r.out.trim();
    // parents가 비어 있으면(root 커밋) jq가 "null"을 낸다 — "철거 전"이 없는 상태라 판정 불가로
    // 접는다(미확정 → 이 사이클 미수렴 → 최종 pending). 성공을 내주지 않는 방향이다.
    if (!/^[0-9a-f]{7,40}$/.test(p)) return null;
    parentCache.set(sha, p);
    return p;
  };

  // 6a) absence 수렴(teardown) — 삭제 대상 Application은 Healthy가 될 수 없다(스펙 대기 매트릭스,
  //   plan r2 s5). 두 지점에서 극성이 뒤집힌다: (1) 철거 머지는 표면을 제거하므로 기준 ref에서
  //   표면이 사라져 있어야 요청이 반영된 것 — 남아 있으면 철거 미반영(fail-loud). (2) Application은
  //   sync/health가 아니라 존재/부재로 판정한다(--ignore-not-found: 부재=빈 stdout·exit 0).
  //   DNS 회수는 관측 대상이 아니다 — iac/tf-reconcile 소관을 resultBase가 명시한다.
  if (spec.converge === "absence") {
    // absence 수렴은 머지 SHA를 전제한다 — "철거 전 ref"가 없으면 부재가 관측이 될 수 없다.
    // no-op 동사(noopOnMissingPr: wantRef="main")와 absence는 양립하지 않는다(오늘 그런 조합의 동사는
    // 없다). 조합이 생기면 조용한 무판정 통과가 아니라 여기서 loud로 죽는다.
    if (mergeSha === undefined) return fail("계약 파손: absence 수렴에 머지 SHA가 없다 — 철거 전 ref를 특정할 수 없다(no-op 동사와 absence는 양립 불가)", { run: runRef(), pr: prRef() });
    let before: { ref: string; read: (path: string) => Blob } | undefined;
    for (;;) {
      let surfaceUndecided = false;
      for (const app of spec.applications) {
        const want = requestedBlob(app.surfacePath);
        if (want.kind === "found") return fail(`기준 ref(${wantRef})에 표면(${app.surfacePath})이 남아 있다 — 철거가 반영되지 않았다`, { run: runRef(), pr: prRef() });
        if (want.kind === "error") { surfaceUndecided = true; continue; } // 미확정 — 이 사이클은 수렴 아님
        // want.kind === "absent" — 여기가 종전의 **무판정 통과**였다. blobAt이 404를 absent로 접으므로
        // 경로가 해석되지 않는 모든 사유(경로 오타·표면 드리프트·애초에 없었음)가 "철거 완료"와 같은
        // 값이 되고, 손해 방향이 파괴 승인이다(같은 blobAt을 쓰는 presence 레인은 같은 absent를
        // fail로 읽는다). 부재가 **관측**이 되려면 철거 전 ref에 표면이 실재했어야 한다.
        if (before === undefined) {
          const parent = firstParentOf(mergeSha);
          if (parent === null) { surfaceUndecided = true; continue; } // 부모 조회 미확정
          before = { ref: parent, read: blobReader(parent) };
        }
        const had = before.read(app.surfacePath);
        if (had.kind === "error") { surfaceUndecided = true; continue; } // 미확정
        if (had.kind === "absent") {
          return fail(`철거 전 ref(${before.ref})에도 표면(${app.surfacePath})이 없다 — 부재가 철거의 증거가 아니다(경로 오타·표면 드리프트·이미 부재가 구별되지 않는다)`, { run: runRef(), pr: prRef() });
        }
      }
      const states: Array<Record<string, unknown>> = [];
      let allAbsent = !surfaceUndecided;
      for (const app of spec.applications) {
        const k = sh("kubectl", ["-n", "argocd", "get", "applications.argoproj.io", app.name, "-o", "json", "--ignore-not-found"]);
        if (!k.ok) { states.push({ name: app.name, error: k.err.split("\n")[0] || "kubectl 실패" }); allAbsent = false; continue; }
        const present = k.out.trim() !== "";
        states.push({ name: app.name, present });
        if (present) allAbsent = false;
      }
      if (allAbsent) {
        return { variant: doneVariant, omitted: [], result: compact({ ...base, waited: true, run: runRef(), pr: prRef(), applications: states }) };
      }
      if (Date.now() >= endAt) {
        // pendingReason은 실제 미수렴 원인을 반영한다 — 표면 조회 일시 실패나 kubectl 오류를
        // "finalizer cascade 진행 중"으로 뭉개면 운영자를 잘못 유도한다(원인별 재조회 판단이 다르다).
        const kubectlError = states.some((s) => s.error !== undefined);
        const pendingReason = surfaceUndecided
          ? "철거 반영 확인 미완 — 표면/철거 전 ref(git) 조회가 일시 실패했다(핸들로 재조회 가능)"
          : kubectlError
            ? "Application 부재 미확정 — 클러스터 조회 일시 실패(핸들로 재조회 가능)"
            : "Application prune 미완 — appset finalizer cascade 진행 중일 수 있다(핸들로 재조회 가능)";
        return { variant: "pending", omitted: [], result: compact({ ...base, run: runRef(), pr: prRef(), applications: states, pendingReason }) };
      }
      Bun.sleepSync(opts.pollMs);
    }
  }

  // 6b) presence 수렴(기본) — 후손 + Synced + Healthy + 표면 요청값.
  // 후손 판정 — gh compare(--jq .status는 raw 문자열이다: JSON.parse 금지). 확정 관측만 캐시한다
  // (리비전의 계보는 불변) — 전송 오류를 false로 캐시하면 수렴 완료가 pending으로 접힌다.
  const descendantCache = new Map<string, boolean>();
  const isDescendant = (revision: string): boolean => {
    if (mergeSha === undefined) return true; // no-op: 머지가 없으니 계보 조건이 없다 — 표면 동치가 판정
    if (revision === mergeSha) return true;
    const hit = descendantCache.get(revision);
    if (hit !== undefined) return hit;
    const r = sh("gh", ["api", `repos/${HOMELAB_REPO}/compare/${mergeSha}...${revision}`, "--jq", ".status"]);
    if (!r.ok) return false; // 미확정 — 캐시하지 않는다(다음 사이클 재평가)
    const status = r.out.trim();
    const yes = status === "identical" || status === "ahead";
    descendantCache.set(revision, yes);
    return yes;
  };
  for (;;) {
    const states: Array<Record<string, unknown>> = [];
    let allConverged = true;
    for (const app of spec.applications) {
      const k = sh("kubectl", ["-n", "argocd", "get", "applications.argoproj.io", app.name, "-o", "json"]);
      if (!k.ok) { states.push({ name: app.name, error: k.err.split("\n")[0] || "kubectl 실패" }); allConverged = false; continue; }
      let st: Record<string, any>;
      try { st = JSON.parse(k.out)?.status ?? {}; } catch { states.push({ name: app.name, error: "Application JSON 파싱 실패" }); allConverged = false; continue; }
      // 리비전 해석은 공유 리더(argocd.ts) — 앱 레인(멀티소스)은 revisions[], db/cache(단일소스)는 revision.
      const rev = syncRevisionOf(st);
      const sync = String(st.sync?.status ?? "Unknown");
      const health = String(st.health?.status ?? "Unknown");
      // 계보: resolved면 그 리비전, skew면 원소 **전부** 후손이어야 true(한 source만 낡은 상태를 후손으로
      // 접지 않는다). non-sha·none은 false이고 gh compare를 부르지 않는다 — 비-SHA(helm 차트 버전)는
      // compare 피연산자가 아니고, 관측 0은 판정 재료가 아니다.
      const descendant = rev.kind === "resolved" ? isDescendant(rev.revision)
        : rev.kind === "skew" ? rev.revisions.every((r) => isDescendant(r))
        : false;
      // 표면은 **확정된 하나의** 후손 리비전에서만 판정 의미가 있다 — stale 리비전의 표면 상태는 추월의
      // 증거가 아니고, skew는 표면 ref를 하나로 고를 수 없어 그 사이클은 미확정이다(수렴 아님).
      let surfaceOk: boolean | undefined;
      let supersededBy: string | undefined;
      if (descendant && rev.kind === "resolved") {
        const revision = rev.revision;
        const want = requestedBlob(app.surfacePath);
        if (want.kind === "absent") {
          return fail(`기준 ref(${wantRef})에 표면(${app.surfacePath})이 없다 — 요청이 반영되지 않음`, { run: runRef(), pr: prRef() });
        }
        if (want.kind === "found") {
          const got = revision === mergeSha ? want : blobAt(revision, app.surfacePath);
          if (got.kind === "absent") { supersededBy = `표면(${app.surfacePath}) 부재`; surfaceOk = false; }
          else if (got.kind === "found" && got.sha !== want.sha) { supersededBy = `표면(${app.surfacePath})이 요청값과 다른 내용`; surfaceOk = false; }
          else if (got.kind === "found") surfaceOk = true;
          // got.kind === "error" → 미확정: surfaceOk 미기록, 이 사이클은 수렴 아님
        }
        // want.kind === "error" → 미확정: 같은 처리
      }
      states.push(compact({ name: app.name, sync, health, ...revisionFields(rev), descendant: mergeSha === undefined ? undefined : descendant, surfaceOk }));
      if (supersededBy !== undefined && mergeSha !== undefined && rev.kind === "resolved") {
        return { variant: "superseded", omitted: [], result: compact({ ...base, run: runRef(), pr: prRef(), applications: states, error: `관측 리비전(${rev.revision})에서 ${supersededBy} — 요청이 추월됨(superseded)` }) };
      }
      if (!(descendant && sync === "Synced" && health === "Healthy" && surfaceOk === true)) allConverged = false;
    }
    if (allConverged) {
      return { variant: doneVariant, omitted: [], result: compact({ ...base, waited: true, run: runRef(), pr: prRef(), applications: states }) };
    }
    if (Date.now() >= endAt) {
      return { variant: "pending", omitted: [], result: compact({ ...base, run: runRef(), pr: prRef(), applications: states, pendingReason: noop ? "no-op 검증 미수렴 — 클러스터가 main의 표면을 아직 반영하지 않음(핸들로 재조회 가능)" : "Application 집합 미수렴 — 핸들로 재조회 가능" }) };
    }
    Bun.sleepSync(opts.pollMs);
  }
}
