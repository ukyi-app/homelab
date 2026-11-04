// deploy-merge의 merge job 본체(.github/workflows/deploy-merge.yaml, 설계 C.4.7). check job이 고른 PR을 검사한 head SHA로
// squash 병합한다.
//
// 입력 env: PR, SHA(check 출력), MERGE_TOKEN(병합 App 토큰), GH_TOKEN(읽기 전용 GITHUB_TOKEN), GITHUB_EVENT_PATH.
// exit 0은 "그 SHA로 병합됨"뿐이다. 그 밖은 모두 exit 1이고 PR은 열린 채 사람이 판단한다.
//
// 병합 API의 5xx는 "병합 안 됨"을 뜻하지 않는다(실측: 병합 6초 뒤 502). 그래서 시도마다 실제 상태부터 읽는다.
// 실패 job만 재실행하면 check 판정이 재사용되므로, 조건 9개는 첫 시도를 포함해 PUT 직전마다 다시 본다.
import { readFileSync } from "node:fs";
import { evaluate } from "./conditions";
import { gather } from "./main";

const API = "https://api.github.com";
const HOMELAB = "ukyi-app/homelab";
const MARKER = "<!-- deploy-merge-merge -->";

// 시도 뒤 기다리는 초. 앞 넷이 PUT 사이 간격이고 마지막은 마지막 PUT의 결과를 확인하기 전 대기다.
// 합 7분: 실측한 502는 3분 넘게 이어졌고 9분 안에 풀렸다(정확한 회복 시점은 모른다). job timeout(15분)은 이 합, 시도마다의
// 조건 재검사, 요청 시간 제한을 더한 값보다 크게 둔다.
export const WAIT_SECONDS = [30, 60, 120, 180, 30];
// 병합 API가 502를 돌려주기까지 11초 걸린 실측이 있어 더 넉넉히 둔다. 넘으면 네트워크 오류로 보고 상태를 읽는다.
const REQUEST_TIMEOUT_MS = 30_000;

export type Api = { status: number; body: any };
export type Recheck = { failures: string[]; transient?: string };
export type Kind = "merged" | "already-merged" | "merged-other-head" | "head-changed" | "closed" | "conditions" | "rejected" | "exhausted";
export type Outcome = { ok: boolean; kind: Kind; reason: string };

export type Io = {
  readPull(): Promise<Api>;
  recheck(): Promise<Recheck>;
  putMerge(): Promise<Api>;
  sleep(ms: number): Promise<void>;
  log(line: string): void;
};

const fail = (kind: Kind, reason: string): Outcome => ({ ok: false, kind, reason });

function describe(r: Api): string {
  const message = r.body?.message;
  if (r.status === 0) return `네트워크 오류: ${message}`;
  return `HTTP ${r.status}${typeof message === "string" ? `: ${message}` : ""}`;
}

const isTransient = (status: number) => status === 0 || status >= 500;

// PR의 실제 상태. done이 있으면 더 시도할 일이 없고, transient가 있으면 상태를 모르며, 둘 다 없으면 열린 채 검사한 head다.
function judgePull(r: Api, sha: string): { done?: Outcome; transient?: string } {
  if (isTransient(r.status)) return { transient: `PR 조회 ${describe(r)}` };
  if (r.status !== 200) return { done: fail("rejected", `PR 조회 ${describe(r)}`) };
  const head = r.body?.head?.sha;
  if (typeof r.body?.merged !== "boolean" || typeof head !== "string") return { transient: "PR 조회 응답에 merged·head.sha가 없다" };
  if (r.body.merged) {
    return head === sha
      ? { done: { ok: true, kind: "already-merged", reason: `이미 병합됐다(head ${sha})` } }
      : { done: fail("merged-other-head", `검사한 ${sha}가 아니라 ${head}로 병합됐다`) };
  }
  if (r.body.state !== "open") return { done: fail("closed", `병합 없이 닫혔다(state ${r.body.state})`) };
  if (head !== sha) return { done: fail("head-changed", `head가 ${sha}에서 ${head}로 바뀌었다`) };
  return {};
}

export async function mergeWithRetry(io: Io, sha: string, waits: number[] = WAIT_SECONDS): Promise<Outcome> {
  let last = "";
  for (let round = 0; ; round++) {
    const pull = judgePull(await io.readPull(), sha);
    if (pull.done) return pull.done;
    if (pull.transient) last = pull.transient;

    // 마지막 PUT의 5xx도 "병합 안 됨"이 아니라서, 소진은 위에서 상태를 한 번 더 읽은 뒤에만 판정한다.
    if (round === waits.length) {
      const state = pull.transient ? "병합 여부를 확인하지 못했다" : "PR은 열린 채다";
      return fail("exhausted", `${waits.length}번 시도했지만 끝나지 않았다. ${state}. 마지막 오류: ${last}`);
    }

    if (!pull.transient) {
      const check = await io.recheck();
      if (check.failures.length > 0 && !check.transient) return fail("conditions", check.failures.join("\n"));
      if (check.failures.length > 0) {
        // 조회 실패도 거짓 조건으로 접히므로 일시적 오류가 있던 판정은 믿지 않고 다시 읽는다. 여기서 PUT은 하지 않는다.
        last = `조건 재검사 중 ${check.transient}\n${check.failures.join("\n")}`;
      } else {
        const put = await io.putMerge();
        if (put.status === 200 && put.body?.merged === true) return { ok: true, kind: "merged", reason: `병합했다(head ${sha})` };
        last = `병합 API ${describe(put)}`;
        if (!isTransient(put.status) && put.status !== 200) {
          // 앞선 시도의 병합이 뒤늦게 끝나 거부로 보일 수 있어, 거부를 그대로 믿기 전에 상태를 한 번 읽는다.
          const after = judgePull(await io.readPull(), sha);
          if (after.done?.ok) return after.done;
          const detail = after.done?.reason ?? after.transient;
          return fail(after.done?.kind ?? "rejected", detail ? `${last}. ${detail}` : last);
        }
      }
    }

    io.log(`${round + 1}번째 시도 실패(${last}). ${waits[round]}초 뒤 다시 본다.`);
    await io.sleep(waits[round] * 1000);
  }
}

// gather는 조회 실패를 "값 없음"으로 접어 거짓 조건으로 만든다. 그대로 쓰면 읽기 502 한 번이 조건 불일치로 굳으므로,
// 그 fetch를 감싸 5xx·네트워크 오류를 함께 돌려준다. 예외도 일시적 오류로 본다: 502의 HTML 본문을 읽다 나는 경우가
// 그렇고, 끝내 안 풀리면 소진으로 닫힌다. gh attestation verify는 자식 프로세스라 여기서 보이지 않아 조건 5 거짓으로 닫힌다.
export async function recheckConditions(event: unknown, pr: number, sha: string): Promise<Recheck> {
  const real = globalThis.fetch;
  let transient: string | undefined;
  globalThis.fetch = (async (input: any, init?: RequestInit) => {
    try {
      const res = await real(input, { ...init, signal: init?.signal ?? AbortSignal.timeout(REQUEST_TIMEOUT_MS) });
      if (res.status >= 500) transient = `HTTP ${res.status}: ${String(input)}`;
      return res;
    } catch (e) {
      transient = `네트워크 오류: ${String(input)}: ${e}`;
      throw e;
    }
  }) as typeof fetch;
  try {
    const facts = await gather(event);
    const failures = evaluate(facts).failures.map((x) => `조건 ${x.cond} 불일치: ${x.message}`);
    // gather는 head 브랜치로 PR을 다시 찾으므로 그 사이 같은 브랜치에 새 PR이 열리면 다른 PR을 본다.
    if (facts.pr && (facts.pr.number !== pr || facts.pr.headSha !== sha)) {
      failures.push(`재검사한 PR #${facts.pr.number} ${facts.pr.headSha}가 검사한 PR #${pr} ${sha}와 다르다`);
    }
    return { failures, transient };
  } catch (e) {
    return { failures: [`조건 재검사 실패: ${e}`], transient: transient ?? String(e) };
  } finally {
    globalThis.fetch = real;
  }
}

async function call(path: string, token: string, init: RequestInit = {}): Promise<Api> {
  try {
    const res = await fetch(`${API}/${path}`, {
      ...init,
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
      },
    });
    const text = await res.text();
    let body: any;
    try {
      body = JSON.parse(text);
    } catch {
      body = undefined;
    }
    return { status: res.status, body };
  } catch (e) {
    return { status: 0, body: { message: String(e) } };
  }
}

// 읽기는 GITHUB_TOKEN으로 한다. 병합 App 토큰은 PUT과 사유 댓글에만 쓴다.
export function githubIo(o: { pr: number; sha: string; readToken: string; mergeToken: string; event: unknown }): Io {
  return {
    readPull: () => call(`repos/${HOMELAB}/pulls/${o.pr}`, o.readToken),
    recheck: () => recheckConditions(o.event, o.pr, o.sha),
    putMerge: () =>
      call(`repos/${HOMELAB}/pulls/${o.pr}/merge`, o.mergeToken, {
        method: "PUT",
        body: JSON.stringify({ merge_method: "squash", sha: o.sha }),
      }),
    sleep: (ms) => Bun.sleep(ms),
    log: (line) => console.log(line),
  };
}

// 사유에는 API 메시지와 PR의 파일 이름이 들어간다. 줄바꿈을 살려 두면 뒷줄이 workflow command로 읽힌다.
export function errorAnnotation(reason: string): string {
  return `::error::${reason.replace(/%/g, "%25").replace(/\r/g, "%0D").replace(/\n/g, "%0A")}`;
}

// 사유는 run 로그만으로는 PR에서 보이지 않아(workflow_run 실행은 PR 검사 목록에 없다) 댓글로도 남긴다.
// 댓글 실패는 병합 결과를 바꾸지 않는다.
export async function commentFailure(pr: number, sha: string, outcome: Outcome, mergeToken: string): Promise<void> {
  const body = `${MARKER}\n자동 병합을 끝내지 못했다(${outcome.kind}, 검사한 head ${sha}). 사람이 보고 판단한다.\n\n${outcome.reason}`;
  const r = await call(`repos/${HOMELAB}/issues/${pr}/comments`, mergeToken, { method: "POST", body: JSON.stringify({ body }) });
  if (r.status >= 300 || r.status === 0) console.log(`댓글 실패: ${describe(r)}`);
}

async function main(): Promise<number> {
  const { PR = "", SHA = "", MERGE_TOKEN = "", GH_TOKEN = "", GITHUB_EVENT_PATH = "" } = process.env;
  if (!/^[0-9]+$/.test(PR) || !/^[0-9a-f]{40}$/.test(SHA)) {
    console.log(errorAnnotation("check 출력이 틀렸다"));
    return 1;
  }
  // gh attestation verify가 process.env를 물려받는다. 병합 토큰은 자식 프로세스에 넘기지 않는다.
  delete process.env.MERGE_TOKEN;
  const pr = Number(PR);
  const event = JSON.parse(readFileSync(GITHUB_EVENT_PATH, "utf8"));
  const outcome = await mergeWithRetry(githubIo({ pr, sha: SHA, readToken: GH_TOKEN, mergeToken: MERGE_TOKEN, event }), SHA);
  if (outcome.ok) {
    console.log(`PR #${pr}: ${outcome.reason}`);
    return 0;
  }
  console.log(errorAnnotation(`PR #${pr} 병합 안 됨(${outcome.kind}): ${outcome.reason}`));
  await commentFailure(pr, SHA, outcome, MERGE_TOKEN);
  return 1;
}

if (import.meta.main) process.exit(await main());
