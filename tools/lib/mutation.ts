// 공유 변이 엔진 — 변이 동사(db/cache create, app create/secrets/teardown)의 공통 골격.
//   correlation nonce 생성 → 디스패치(gh workflow run) → nonce 에코 run-name으로 자기 run 특정
//   (정확히 1개만 채택: ≥2 = race fail-closed, 0 = 재조회 후 pending — 관측 차분은 신원
//   메커니즘이 아니다, 스펙 run 특정 절) → run conclusion 추적(실패 시 실패 잡 열거 + run URL)
//   → run_id 브랜치로 PR 특정 → [--wait] 머지 관측(자동/수동 레인) → 명명된 Application 집합 전체 수렴.
// 수렴 판정(스펙 대기 매트릭스): 관측 sync revision이 머지 SHA와 동일하거나 그 후손(gh compare —
//   로컬 git 이력 무의존) AND Synced AND Healthy AND 관측 리비전에서 desired-state 표면 실존.
//   health 단독 판정 금지(stale-Healthy: 이전 리비전 Healthy+OutOfSync에서 성공 오판).
//   표면 술어(스펙: "존재·내용이 여전히 요청값"): 관측 리비전의 blob sha == 머지 SHA 시점의
//   blob sha — 제거형·변경형 추월을 모두 superseded로 포착한다(전제 상태 변동 — exit 3 계열).
//   3상 판정: found/absent(HTTP 404 확정)/error(전송 오류) — 전송 오류는 추월의 증거가 아니라
//   그 사이클 미확정이다(일시 실패 한 번이 exit 3 종결이 되면 안 된다).
//   absence 수렴(teardown)의 표면 축은 두 ref를 본다 — 머지 SHA에서 부재 AND 철거 전 ref(first
//   parent)에서 실재. 부재 한 축만 보면 404의 모든 사유가 "철거 완료"와 같은 값이 된다.
// KUBECONFIG 부재: 머지까지 확인하고 라이브 구간은 omitted=["live"]로 명시(생략 ≠ 성공 은폐).
// 시간 심: pollMs·deadlineMs 주입(테스트가 밀리초로 돌린다), nonce는 HOMELAB_CORRELATION 주입.
import { randomBytes } from "node:crypto";
import { compact } from "./contract.ts";
import { ghJson, sh } from "./exec.ts";
import { CORRELATION_RE } from "./identity.ts";
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
};

export type MutationOpts = { wait: boolean; pollMs: number; deadlineMs: number; identifyOnly: boolean };

// 대기 옵션 SSOT — 기본값과 검증 술어를 변이 동사 전부가 공유한다(콜사이트 인라인 사본 금지).
export const WAIT_DEFAULTS = { pollMs: 5_000, deadlineMs: 1_200_000 } as const;
// identifyOnly: run 식별 직후 run 핸들을 pending으로 반환하고 conclusion 추적(최대 deadline)을 건너뛴다.
// MCP 전용(release r1 a2=b3) — stdio 서버는 단일 스레드라 conclusion 폴링이 서버를 최대 20분 블로킹한다.
// 스펙의 "결과의 run URL이 상관 핸들, 진행 확인은 status 핸들 조회로"를 실행형으로 만든다. CLI는 미설정.
export type WaitInput = { wait?: boolean; pollMs?: number; deadlineMs?: number; identifyOnly?: boolean };
export function waitInputError(input: WaitInput): string | null {
  if (input.pollMs !== undefined && !(Number.isInteger(input.pollMs) && input.pollMs > 0)) return `--poll-ms는 양의 정수여야 한다: ${input.pollMs}`;
  if (input.deadlineMs !== undefined && !(Number.isInteger(input.deadlineMs) && input.deadlineMs > 0)) return `--deadline-ms는 양의 정수여야 한다: ${input.deadlineMs}`;
  return null;
}
export function waitOpts(input: WaitInput): MutationOpts {
  return { wait: input.wait === true, pollMs: input.pollMs ?? WAIT_DEFAULTS.pollMs, deadlineMs: input.deadlineMs ?? WAIT_DEFAULTS.deadlineMs, identifyOnly: input.identifyOnly === true };
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
type PrRow = { number: number; html_url: string; merged_at: string | null; merge_commit_sha: string | null };

export function runMutation(spec: MutationSpec, opts: MutationOpts): MutationOutcome {
  const correlation = newNonce();
  const base = { ...spec.resultBase, correlation };
  const endAt = Date.now() + opts.deadlineMs;
  const fail = (error: string, extra: Record<string, unknown> = {}): MutationOutcome =>
    ({ variant: "failure", omitted: [], result: compact({ ...base, ...extra, error }) });

  // 1) 디스패치 — 유일한 변이 argv. correlation이 run-name에 에코된다(수령증).
  const dispatchArgs = ["workflow", "run", spec.workflow, "-R", HOMELAB_REPO];
  for (const [k, v] of spec.dispatchInputs) dispatchArgs.push("-f", `${k}=${v}`);
  dispatchArgs.push("-f", `correlation=${correlation}`);
  const dispatched = sh("gh", dispatchArgs);
  if (!dispatched.ok) return fail(`디스패치 실패 — ${dispatched.err.split("\n")[0] || "gh workflow run 비-0"}`);

  // 2) 자기 run 특정 — run-name의 [nonce] 에코가 권위. 정확히 1개일 때만 채택.
  let run: RunRow | undefined;
  for (;;) {
    const got = ghJson(`repos/${HOMELAB_REPO}/actions/workflows/${spec.workflow}/runs?per_page=20`,
      "[.workflow_runs[] | {id, name, status, conclusion, html_url}]");
    if (got !== null) {
      const mine = (got as RunRow[]).filter((r) => r.name.includes(`[${correlation}]`));
      if (mine.length >= 2) {
        return { variant: "race", omitted: [], result: compact({ ...base, observedRuns: mine.length, error: `같은 correlation을 에코하는 run이 ${mine.length}개 — 신원 판정 불가(fail-closed)` }) };
      }
      if (mine.length === 1) { run = mine[0]; break; }
    }
    if (Date.now() >= endAt) {
      return { variant: "pending", omitted: [], result: compact({ ...base, pendingReason: "run 미출현(디스패치는 접수됨) — 큐/크론 지연 가능, 같은 correlation으로 재조회 가능" }) };
    }
    Bun.sleepSync(opts.pollMs);
  }
  const runRef = () => compact({ id: run!.id, url: run!.html_url, conclusion: run!.conclusion ?? undefined });

  // 2b) identifyOnly(MCP) — run을 식별했으면 conclusion 추적 없이 run 핸들을 pending으로 즉시 반환한다.
  // stdio 서버가 GitHub Actions run 완료(최대 deadline)까지 블로킹하지 않게 한다 — 진행은 status(run URL)
  // 재조회가 재개 경로다(스펙 "결과의 run URL이 상관 핸들, 진행 확인은 status 핸들 조회로", release r1 a2=b3).
  if (opts.identifyOnly) {
    return { variant: "pending", omitted: [], result: compact({ ...base, run: runRef(), pendingReason: "run 디스패치·식별 완료 — 진행은 status 핸들(run URL) 조회로 확인(동기 바운디드)" }) };
  }

  // 3) conclusion 추적 — queued/in_progress면 폴링, 실패면 실패 잡 열거.
  while (run.status !== "completed") {
    if (Date.now() >= endAt) {
      return { variant: "pending", omitted: [], result: compact({ ...base, run: runRef(), pendingReason: "run 진행 중 — 핸들(run URL)로 재조회 가능" }) };
    }
    Bun.sleepSync(opts.pollMs);
    const got = ghJson(`repos/${HOMELAB_REPO}/actions/runs/${run.id}`, "{status, conclusion, html_url}");
    if (got !== null) run = { ...run, ...(got as Partial<RunRow>) };
  }
  if (run.conclusion !== "success") {
    const jobs = ghJson(`repos/${HOMELAB_REPO}/actions/runs/${run.id}/jobs`,
      '[.jobs[] | select(.conclusion == "failure") | .name]');
    return fail(`run 실패(${run.conclusion})`, { run: compact({ ...runRef(), failedJobs: jobs ?? undefined }) });
  }

  // 4) PR 특정 — run_id 브랜치(reusable 명명 SSOT)로 권위 조회.
  const branch = spec.branchFor(run.id);
  const owner = HOMELAB_REPO.split("/")[0];
  const readPr = (): PrRow[] | null =>
    ghJson(`repos/${HOMELAB_REPO}/pulls?state=all&head=${owner}:${branch}`,
      "[.[] | {number, html_url, merged_at, merge_commit_sha}]") as PrRow[] | null;
  let prs = readPr();
  if (prs === null) return fail("PR 조회 실패 — GitHub 계층", { run: runRef() });
  const noop = prs.length === 0 && spec.noopOnMissingPr === true;
  if (prs.length === 0 && !noop) return fail(`run은 성공했으나 브랜치(${branch})의 PR이 없다 — 명명 드리프트(no-op 동사가 아님)`, { run: runRef() });
  if (prs.length >= 2) {
    return { variant: "race", omitted: [], result: compact({ ...base, run: runRef(), observedRuns: prs.length, error: `브랜치 ${branch}에 PR이 ${prs.length}개 — 신원 판정 불가(fail-closed)` }) };
  }
  let pr: PrRow | undefined = noop ? undefined : prs[0];
  const prRef = () => (pr === undefined ? undefined
    : compact({ number: pr.number, url: pr.html_url, merged: pr.merged_at !== null, mergeSha: pr.merge_commit_sha ?? undefined }));
  const doneVariant = noop ? "no-op" : "success";

  if (!opts.wait) {
    return { variant: doneVariant, omitted: [], result: compact({ ...base, waited: false, run: runRef(), pr: prRef() }) };
  }

  // 5) 머지 관측 — 자동 머지 동사는 required check(gate) 통과 후 auto-merge가, 수동 머지 동사
  // (manualMerge: create-app — 머지가 곧 공개 승인)는 사람이 머지한다. no-op은 머지가 없다.
  let mergeSha: string | undefined;
  if (pr !== undefined) {
    while (pr.merged_at === null) {
      if (Date.now() >= endAt) {
        return { variant: "pending", omitted: [], result: compact({ ...base, run: runRef(), pr: prRef(), pendingReason: spec.manualMerge !== undefined ? `사람 머지 대기 — 머지가 곧 ${spec.manualMerge.approval}(PR 검토·머지 후 핸들로 재조회)` : "auto-merge 머지 미관측 — required check 대기 중일 수 있다(핸들로 재조회 가능)" }) };
      }
      Bun.sleepSync(opts.pollMs);
      const again = readPr();
      if (again !== null && again.length === 1) pr = again[0];
    }
    mergeSha = pr.merge_commit_sha ?? undefined;
    if (!mergeSha) return fail("머지는 관측됐으나 merge SHA가 비어 있다 — GitHub 응답 이상", { run: runRef(), pr: prRef() });
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
      const revision = String(st.sync?.revision ?? "");
      const sync = String(st.sync?.status ?? "Unknown");
      const health = String(st.health?.status ?? "Unknown");
      const descendant = revision !== "" && isDescendant(revision);
      // 표면은 후손 리비전에서만 판정 의미가 있다 — stale 리비전의 표면 상태는 추월의 증거가 아니다.
      let surfaceOk: boolean | undefined;
      let supersededBy: string | undefined;
      if (descendant) {
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
      states.push(compact({ name: app.name, sync, health, revision, descendant: mergeSha === undefined ? undefined : descendant, surfaceOk }));
      if (supersededBy !== undefined && mergeSha !== undefined) {
        return { variant: "superseded", omitted: [], result: compact({ ...base, run: runRef(), pr: prRef(), applications: states, error: `관측 리비전(${revision})에서 ${supersededBy} — 요청이 추월됨(superseded)` }) };
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
