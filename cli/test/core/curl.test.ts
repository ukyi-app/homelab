// curl 판정 독립 시험(#873 1라운드 P1). 판정(classify)을 믿지 않고 실제 curl과 127.0.0.1 서버로 보낸 메서드를 관측한다.
// HOME에 request = POST를 넣은 .curlrc를 두고, 판정이 읽기라고 한 꼴은 서버가 GET·HEAD만 받고 파일을 남기지 않아야 한다.
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { existsSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { classify } from "../../src/core/writes";

const curlBin = Bun.which("curl");
let server: ReturnType<typeof Bun.serve>;
let home: string;
const seen: string[] = [];

beforeAll(() => {
  server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: (req) => (seen.push(req.method), new Response("ok")) });
  home = mkdtempSync(join(tmpdir(), "homelab-cli-curl-"));
  writeFileSync(join(home, ".curlrc"), 'request = "POST"\ndata = "x=1"\n');
  writeFileSync(join(home, "cfg"), 'request = "POST"\ndata = "x=1"\n');
});
afterAll(() => {
  server.stop(true);
  rmSync(home, { recursive: true, force: true });
});

async function observe(argv: string[], stdin?: string): Promise<string[]> {
  seen.length = 0;
  const p = Bun.spawn([curlBin!, ...argv.slice(1)], { cwd: home, env: { HOME: home, PATH: "/usr/bin:/bin" }, stdin: stdin === undefined ? "ignore" : new TextEncoder().encode(stdin), stdout: "ignore", stderr: "ignore" });
  await p.exited;
  return [...seen];
}

describe.skipIf(!curlBin)("curl: 판정과 실제 메서드", () => {
  const url = () => `http://127.0.0.1:${server.port}/x`;
  const cases = (): { argv: string[]; stdin?: string }[] => [
    { argv: ["curl", "-q", "-s", "-o", "/dev/null", "-w", "%{http_code}", url()] },
    { argv: ["curl", "-q", "-sSfL", "-X", "GET", "-m", "5", "-H", "Accept: application/json", url()] },
    { argv: ["curl", "-q", "-I", url()] },
    // 아래는 판정이 쓰기라고 해야 한다(실제로 POST를 보낸다).
    { argv: ["curl", "-s", url()] },
    { argv: ["curl", "-q", "--config", "-", url()], stdin: 'request = "POST"\n' },
    { argv: ["curl", "-q", "-K", "cfg", url()] },
    { argv: ["curl", "-q", "-d", "x=1", url()] },
    { argv: ["curl", "-q", "-sd", "x=1", url()] },
    { argv: ["curl", "-q", "-XPOST", url()] },
    { argv: ["curl", "-q", "--json", "{}", url()] },
    { argv: ["curl", "-q", "-o", "out", url()] },
    { argv: ["curl", "-q", "-w", "%output{w.txt}x", url()] },
  ];

  test("판정이 읽기면 서버는 GET·HEAD만 받고 HOME에 새 파일이 없다", async () => {
    let reads = 0;
    for (const c of cases()) {
      const before = readdirSync(home).sort();
      const methods = await observe(c.argv, c.stdin);
      if (classify(c.argv).write) continue;
      reads++;
      expect([c.argv.join(" "), methods.every((m) => m === "GET" || m === "HEAD")]).toEqual([c.argv.join(" "), true]);
      expect(readdirSync(home).sort()).toEqual(before);
    }
    expect(reads).toBe(3);
  });

  test("대조군: -q 없는 curl은 .curlrc 때문에 실제로 POST를 보낸다(그래서 쓰기로 본다)", async () => {
    const argv = ["curl", "-s", url()];
    expect(await observe(argv)).toEqual(["POST"]);
    expect(classify(argv).write).toBe(true);
    expect(existsSync(join(home, ".curlrc"))).toBe(true);
  });
});
