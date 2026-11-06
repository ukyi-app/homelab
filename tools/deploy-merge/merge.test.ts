// merge job 시험(tools/deploy-merge/merge.ts). GitHub은 fetch 자리의 가짜로 대신하고, PR 응답의 모양은 실제 병합된
// PR을 읽어 맞췄다(state·merged·head.sha). 판정은 fixture 사실에 진짜 evaluate를 돌린다.
import { afterEach, describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { type Facts, evaluate } from "./conditions";
import { type Api, WAIT_SECONDS, commentFailure, errorAnnotation, githubIo, mergeWithRetry, recheckConditions } from "./merge";

const FIXTURES = "tools/deploy-merge/fixtures";
const ok = JSON.parse(readFileSync(`${FIXTURES}/ok.json`, "utf8")) as Facts;
const PR = ok.pr!.number;
const SHA = ok.pr!.headSha;
const OTHER = "e".repeat(40);

const patched = (name: string): Facts => {
  const merge = (a: any, b: any): any => {
    if (b && typeof b === "object" && !Array.isArray(b) && a && typeof a === "object" && !Array.isArray(a)) {
      const o = { ...a };
      for (const [k, v] of Object.entries(b)) o[k] = merge(a[k], v);
      return o;
    }
    return b;
  };
  return merge(ok, JSON.parse(readFileSync(`${FIXTURES}/${name}.json`, "utf8")).patch);
};

const open = (sha = SHA): Api => ({ status: 200, body: { state: "open", merged: false, head: { sha } } });
const merged = (sha = SHA): Api => ({ status: 200, body: { state: "closed", merged: true, head: { sha } } });
const closed = (): Api => ({ status: 200, body: { state: "closed", merged: false, head: { sha: SHA } } });
const putOk = (): Api => ({ status: 200, body: { merged: true, sha: "f".repeat(40), message: "Pull Request successfully merged" } });
const http = (status: number, message?: string): Api => ({ status, body: message ? { message } : undefined });
const down: Api = { status: 0, body: { message: "connect ECONNRESET" } };

// 응답 목록을 앞에서부터 쓴다. 목록이 비면 마지막 응답을 반복하고, facts는 재검사 때마다 하나씩 쓴다.
function scenario(s: { pulls: Api[]; puts?: Api[]; facts?: Facts[] }) {
  const calls = { pulls: 0, puts: 0, rechecks: 0, order: [] as string[] };
  const sleeps: number[] = [];
  const take = <T>(list: T[], i: number): T => list[Math.min(i, list.length - 1)];
  const io = {
    readPull: async () => {
      calls.order.push("read");
      return take(s.pulls, calls.pulls++);
    },
    recheck: async () => {
      calls.order.push("recheck");
      const facts = s.facts ? take(s.facts, calls.rechecks) : ok;
      calls.rechecks++;
      return { failures: evaluate(facts).failures.map((x) => `조건 ${x.cond} 불일치: ${x.message}`) };
    },
    putMerge: async () => {
      calls.order.push("put");
      return take(s.puts ?? [putOk()], calls.puts++);
    },
    sleep: async (ms: number) => {
      sleeps.push(ms);
    },
    log: () => {},
  };
  return { io, calls, sleeps };
}

describe("봇 변경 PR 신원(AC-P8)", () => {
  const WRITER = patched("1-writer-author");

  test("deploy/ 브랜치의 정상 digest PR이어도 작성자가 writer면 조건 1 하나로 거부한다", () => {
    expect(evaluate(WRITER).failures.map((x) => x.cond)).toEqual([1]);
  });

  test("실제 모양(bot/ head)은 조건 1·2로 거부하고, 조건 2에서 끝나도 조건 1이 사유에 남는다", () => {
    const facts: Facts = {
      ...WRITER,
      pr: { ...WRITER.pr!, headRef: "bot/ac-p8-synthetic" },
      run: { ...WRITER.run, headBranch: "bot/ac-p8-synthetic" },
    };
    const { failures } = evaluate(facts);
    expect(failures.map((x) => x.cond)).toEqual([1, 2]);
    expect(failures[0].message).toContain("2000003");
  });

  test("판정 뒤 조건이 어긋나면 재검사에서 멈추고 PUT하지 않는다", async () => {
    const { io, calls } = scenario({ pulls: [open()], facts: [WRITER] });
    const out = await mergeWithRetry(io, SHA);
    expect(out).toMatchObject({ ok: false, kind: "conditions" });
    expect(out.reason).toContain("조건 1 불일치");
    expect(calls.puts).toBe(0);
  });
});

describe("검증 사례", () => {
  test("502 → 미병합 → 재시도 성공", async () => {
    const { io, calls, sleeps } = scenario({ pulls: [open(), open()], puts: [http(502, "Server Error"), putOk()] });
    const out = await mergeWithRetry(io, SHA);
    expect(out).toMatchObject({ ok: true, kind: "merged" });
    expect(calls.puts).toBe(2);
    expect(sleeps).toEqual([WAIT_SECONDS[0] * 1000]);
    // 재시도도 상태 → 조건 → PUT 순서다.
    expect(calls.order).toEqual(["read", "recheck", "put", "read", "recheck", "put"]);
  });

  test("502지만 이미 병합", async () => {
    const { io, calls } = scenario({ pulls: [open(), merged()], puts: [http(502, "Server Error")] });
    const out = await mergeWithRetry(io, SHA);
    expect(out).toMatchObject({ ok: true, kind: "already-merged" });
    expect(calls.puts).toBe(1);
    expect(calls.rechecks).toBe(1);
  });

  test("head 변경", async () => {
    const { io, calls } = scenario({ pulls: [open(), open(OTHER)], puts: [http(502, "Server Error")] });
    const out = await mergeWithRetry(io, SHA);
    expect(out).toMatchObject({ ok: false, kind: "head-changed" });
    expect(out.reason).toContain(OTHER);
    expect(calls.puts).toBe(1);
  });

  test("hold 설정", async () => {
    for (const fixture of ["8-hold-label", "4-hold"]) {
      const { io, calls } = scenario({ pulls: [open(), open()], puts: [http(502, "Server Error")], facts: [ok, patched(fixture)] });
      const out = await mergeWithRetry(io, SHA);
      expect(out).toMatchObject({ ok: false, kind: "conditions" });
      expect(out.reason).toContain("hold");
      expect(calls.puts).toBe(1);
    }
  });

  test("재시도 소진", async () => {
    const { io, calls, sleeps } = scenario({ pulls: [open()], puts: [http(502, "Server Error")] });
    const out = await mergeWithRetry(io, SHA);
    expect(out).toMatchObject({ ok: false, kind: "exhausted" });
    expect(out.reason).toContain("HTTP 502");
    expect(out.reason).toContain("PR은 열린 채다");
    expect(calls.puts).toBe(WAIT_SECONDS.length);
    expect(sleeps).toEqual(WAIT_SECONDS.map((s) => s * 1000));
    // 마지막 PUT 뒤에도 상태를 한 번 더 읽는다.
    expect(calls.pulls).toBe(WAIT_SECONDS.length + 1);
  });
});

describe("상태 확인", () => {
  test("마지막 PUT이 502여도 소진 전 확인에서 병합이면 성공", async () => {
    const pulls = [...WAIT_SECONDS.map(() => open()), merged()];
    const { io, calls } = scenario({ pulls, puts: [http(502)] });
    expect(await mergeWithRetry(io, SHA)).toMatchObject({ ok: true, kind: "already-merged" });
    expect(calls.puts).toBe(WAIT_SECONDS.length);
  });

  test("끝까지 상태를 못 읽으면 소진이고 병합 여부를 모른다고 적는다", async () => {
    const { io, calls } = scenario({ pulls: [http(503)] });
    const out = await mergeWithRetry(io, SHA);
    expect(out).toMatchObject({ ok: false, kind: "exhausted" });
    expect(out.reason).toContain("병합 여부를 확인하지 못했다");
    expect(calls.puts).toBe(0);
    expect(calls.rechecks).toBe(0);
  });

  test("상태를 못 읽는 동안에는 PUT하지 않고, 읽히면 조건부터 다시 본다", async () => {
    const { io, calls } = scenario({ pulls: [http(502), down, open()] });
    expect(await mergeWithRetry(io, SHA)).toMatchObject({ ok: true, kind: "merged" });
    expect(calls.order).toEqual(["read", "read", "read", "recheck", "put"]);
  });

  test("실패 job 재실행: 처음부터 병합돼 있으면 조건도 PUT도 없이 성공", async () => {
    const { io, calls } = scenario({ pulls: [merged()] });
    expect(await mergeWithRetry(io, SHA)).toMatchObject({ ok: true, kind: "already-merged" });
    expect(calls.order).toEqual(["read"]);
  });

  test("다른 head로 병합됐으면 성공이 아니다", async () => {
    const out = await mergeWithRetry(scenario({ pulls: [merged(OTHER)] }).io, SHA);
    expect(out).toMatchObject({ ok: false, kind: "merged-other-head" });
  });

  test("병합 없이 닫혔으면 멈춘다", async () => {
    const { io, calls } = scenario({ pulls: [closed()] });
    expect(await mergeWithRetry(io, SHA)).toMatchObject({ ok: false, kind: "closed" });
    expect(calls.puts).toBe(0);
  });

  test("PR 조회 4xx는 다시 시도하지 않는다", async () => {
    const { io, sleeps } = scenario({ pulls: [http(404, "Not Found")] });
    const out = await mergeWithRetry(io, SHA);
    expect(out).toMatchObject({ ok: false, kind: "rejected" });
    expect(sleeps).toEqual([]);
  });
});

describe("재시도 대상", () => {
  for (const put of [http(500), http(502), http(503), http(504), down]) {
    test(`병합 API ${put.status === 0 ? "네트워크 오류" : put.status}는 다시 시도한다`, async () => {
      const { io, calls } = scenario({ pulls: [open()], puts: [put, putOk()] });
      expect(await mergeWithRetry(io, SHA)).toMatchObject({ ok: true, kind: "merged" });
      expect(calls.puts).toBe(2);
    });
  }

  test("200인데 merged가 없으면 믿지 않고 상태를 다시 읽는다", async () => {
    const { io, calls } = scenario({ pulls: [open(), merged()], puts: [{ status: 200, body: {} }] });
    expect(await mergeWithRetry(io, SHA)).toMatchObject({ ok: true, kind: "already-merged" });
    expect(calls.puts).toBe(1);
  });

  for (const [status, message] of [
    [403, "Resource not accessible by integration"],
    [405, "Repository rule violations found"],
    [409, "Head branch was modified. Review and try the merge again."],
    [422, "Validation Failed"],
    [429, "API rate limit exceeded"],
  ] as const) {
    test(`병합 API ${status}는 다시 시도하지 않고 사유를 남긴다`, async () => {
      const { io, calls, sleeps } = scenario({ pulls: [open()], puts: [http(status, message)] });
      const out = await mergeWithRetry(io, SHA);
      expect(out).toMatchObject({ ok: false, kind: "rejected" });
      expect(out.reason).toContain(String(status));
      expect(out.reason).toContain(message);
      expect(calls.puts).toBe(1);
      expect(sleeps).toEqual([]);
    });
  }

  test("거부 응답이어도 실제로 병합돼 있으면 성공", async () => {
    const { io } = scenario({ pulls: [open(), open(), merged()], puts: [http(502), http(405, "Pull Request is not mergeable")] });
    expect(await mergeWithRetry(io, SHA)).toMatchObject({ ok: true, kind: "already-merged" });
  });

  test("409 뒤 head가 실제로 바뀌었으면 head 변경으로 남긴다", async () => {
    const { io } = scenario({ pulls: [open(), open(OTHER)], puts: [http(409, "Head branch was modified. Review and try the merge again.")] });
    const out = await mergeWithRetry(io, SHA);
    expect(out).toMatchObject({ ok: false, kind: "head-changed" });
    expect(out.reason).toContain("HTTP 409");
    expect(out.reason).toContain(OTHER);
  });

  test("재검사가 끝내 일시적 오류면 소진 사유에 거짓 조건도 남긴다", async () => {
    const { io, calls } = scenario({ pulls: [open()] });
    io.recheck = async () => ({ failures: ["조건 4 불일치: image.yaml"], transient: "HTTP 502" });
    const out = await mergeWithRetry(io, SHA);
    expect(out).toMatchObject({ ok: false, kind: "exhausted" });
    expect(out.reason).toContain("HTTP 502");
    expect(out.reason).toContain("조건 4 불일치");
    expect(calls.puts).toBe(0);
  });

  test("거부 뒤 상태도 못 읽으면 두 사유를 함께 남긴다", async () => {
    const { io } = scenario({ pulls: [open(), http(502)], puts: [http(405, "Pull Request is not mergeable")] });
    const out = await mergeWithRetry(io, SHA);
    expect(out).toMatchObject({ ok: false, kind: "rejected" });
    expect(out.reason).toContain("HTTP 405");
    expect(out.reason).toContain("PR 조회 HTTP 502");
  });

  test("첫 시도 전 조건이 어긋나면 PUT하지 않는다", async () => {
    const { io, calls } = scenario({ pulls: [open()], facts: [patched("8-hold-label")] });
    expect(await mergeWithRetry(io, SHA)).toMatchObject({ ok: false, kind: "conditions" });
    expect(calls.puts).toBe(0);
  });

  test("조건 재검사 중 일시적 오류면 PUT하지 않고 다시 본다", async () => {
    const { io, calls } = scenario({ pulls: [open()] });
    let n = 0;
    io.recheck = async () => (n++ === 0 ? { failures: ["조건 4 불일치"], transient: "HTTP 502" } : { failures: [] });
    expect(await mergeWithRetry(io, SHA)).toMatchObject({ ok: true, kind: "merged" });
    expect(n).toBe(2);
    expect(calls.puts).toBe(1);
  });
});

describe("GitHub 호출", () => {
  const real = globalThis.fetch;
  afterEach(() => {
    globalThis.fetch = real;
  });
  const respond = (handler: (url: string, init?: RequestInit) => Response | Promise<Response>) => {
    globalThis.fetch = (async (input: any, init?: RequestInit) => handler(String(input), init)) as typeof fetch;
  };
  const header = (init: RequestInit | undefined, name: string) => new Headers(init?.headers).get(name);
  const event = { workflow_run: { head_branch: "deploy/homelab-probe" } };

  test("PUT은 병합 토큰과 sha·squash로, 조회는 읽기 토큰으로 한다", async () => {
    const seen: { method: string; url: string; auth: string | null; body?: any }[] = [];
    respond((url, init) => {
      seen.push({ method: init?.method ?? "GET", url, auth: header(init, "Authorization"), body: init?.body ? JSON.parse(String(init.body)) : undefined });
      return Response.json(init?.method === "PUT" ? putOk().body : open().body);
    });
    const io = githubIo({ pr: PR, sha: SHA, readToken: "read", mergeToken: "merge", event });
    expect((await io.readPull()).status).toBe(200);
    expect((await io.putMerge()).body.merged).toBe(true);
    expect(seen[0]).toEqual({ method: "GET", url: `https://api.github.com/repos/ukyi-app/homelab/pulls/${PR}`, auth: "Bearer read", body: undefined });
    expect(seen[1]).toEqual({ method: "PUT", url: `https://api.github.com/repos/ukyi-app/homelab/pulls/${PR}/merge`, auth: "Bearer merge", body: { merge_method: "squash", sha: SHA } });
  });

  test("네트워크 오류는 status 0으로 접고 HTML 502 본문도 견딘다", async () => {
    const io = githubIo({ pr: PR, sha: SHA, readToken: "read", mergeToken: "merge", event });
    respond(() => {
      throw new TypeError("connect ECONNRESET");
    });
    expect(await io.putMerge()).toMatchObject({ status: 0 });
    respond(() => new Response("<html>Bad Gateway</html>", { status: 502 }));
    expect(await io.putMerge()).toEqual({ status: 502, body: undefined });
  });

  test("가짜 GitHub으로 502 → 미병합 → 성공을 끝까지 돈다", async () => {
    let puts = 0;
    respond((_url, init) => {
      if (init?.method !== "PUT") return Response.json(open().body);
      return ++puts === 1 ? new Response("<html>Bad Gateway</html>", { status: 502 }) : Response.json(putOk().body);
    });
    const io = { ...githubIo({ pr: PR, sha: SHA, readToken: "read", mergeToken: "merge", event }), recheck: async () => ({ failures: [] }), sleep: async () => {} };
    expect(await mergeWithRetry(io, SHA)).toMatchObject({ ok: true, kind: "merged" });
    expect(puts).toBe(2);
  });

  test("재검사: 읽기 5xx는 일시적 오류로 돌려주고 fetch를 되돌린다", async () => {
    respond(() => new Response("<html>Bad Gateway</html>", { status: 502 }));
    const before = globalThis.fetch;
    const r = await recheckConditions(event, PR, SHA);
    expect(r.failures.length).toBeGreaterThan(0);
    expect(r.transient).toContain("HTTP 502");
    expect(globalThis.fetch).toBe(before);
  });

  test("재검사: 네트워크 오류도 일시적 오류다", async () => {
    respond(() => {
      throw new TypeError("connect ECONNRESET");
    });
    const r = await recheckConditions(event, PR, SHA);
    expect(r.failures.length).toBeGreaterThan(0);
    expect(r.transient).toContain("네트워크 오류");
  });

  test("재검사: 일시적 오류가 없으면 거짓 조건은 그대로 불일치다", async () => {
    respond(() => Response.json([]));
    const r = await recheckConditions(event, PR, SHA);
    expect(r.failures.join()).toContain("조건 2 불일치");
    expect(r.transient).toBeUndefined();
  });

  test("재검사: 같은 브랜치의 다른 PR이면 불일치다", async () => {
    const pull = { number: PR + 1, user: { id: 1 }, head: { repo: { full_name: "ukyi-app/homelab" }, ref: "other", sha: OTHER }, base: { ref: "main" }, draft: false, labels: [] };
    respond((url) => Response.json(url.includes("/pulls?") ? [pull] : pull));
    const r = await recheckConditions(event, PR, SHA);
    expect(r.failures.join("\n")).toContain("재검사한 PR");
  });

  test("사유 댓글은 병합 토큰으로 남기고 실패해도 던지지 않는다", async () => {
    let auth: string | null = null;
    let body = "";
    respond((_url, init) => {
      auth = header(init, "Authorization");
      body = JSON.parse(String(init?.body)).body;
      return new Response("{}", { status: 403 });
    });
    await commentFailure(PR, SHA, { ok: false, kind: "rejected", reason: "HTTP 405: 규칙 위반" }, "merge");
    expect(auth).toBe("Bearer merge");
    expect(body).toContain("HTTP 405: 규칙 위반");
    expect(body).toContain(SHA);
  });
});

describe("실행", () => {
  test("사유의 줄바꿈이 workflow command로 읽히지 않는다", () => {
    expect(errorAnnotation("가\n::add-mask::x\r100%")).toBe("::error::가%0A::add-mask::x%0D100%25");
  });

  test("check 출력이 틀리면 병합 없이 exit 1", () => {
    for (const env of [{ PR: "1; rm", SHA }, { PR: String(PR), SHA: "abc" }]) {
      const p = Bun.spawnSync(["bun", "tools/deploy-merge/merge.ts"], { env: { ...process.env, ...env, MERGE_TOKEN: "merge", GH_TOKEN: "read" }, stdout: "pipe", stderr: "pipe" });
      expect(p.exitCode).toBe(1);
      expect(p.stdout.toString()).toContain("::error::check 출력이 틀렸다");
    }
  });
});
