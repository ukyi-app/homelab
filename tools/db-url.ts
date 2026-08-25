// db:url — conn URL 엔진(lib/conn-url.ts)의 CLI 껍데기(cli-deepening 심화 5). 접속 로직·평문
// 비출력·F2 채널 분리(--admin ↔ .env.admin.local)·RW/ADMIN 상호배타는 엔진 술어 소유 — 여기는
// argv 파싱과 기존 출력 계약(dry-run 계획 JSON·기록 한 줄·종료코드 0/1/2)만 보존한다.
// homelab CLI(`homelab db url`)와 MCP(db_url)는 catalog op로 같은 엔진을 소비한다.
// 이 도구는 reset/drop 등 파괴 수단을 제공하지 않는다(파괴는 docker 모드 전용).
import { dbUrlInputError, runDbUrl } from "./lib/conn-url.ts";
import { RESOURCE_NAME_RE } from "./lib/identity.ts";
import { parseFlags } from "./lib/cli.ts";

// parseFlags: unknown 옵션 + arg 삼킴 fail-closed. 종료 코드 2 보존.
let __f: Record<string, string | boolean>;
try { __f = parseFlags(process.argv.slice(2), { value: ["--name", "--host", "--env-local"], bool: ["--dry-run", "--rw", "--admin"] }); }
catch (e) { console.error(`db-url: ${e instanceof Error ? e.message : String(e)} (읽기 전용 도구 — 파괴 수단 없음)`); process.exit(2); }
const arg = (k: string) => (typeof __f[k] === "string" ? __f[k] as string : undefined);
const USAGE = "usage: db-url --name <db> [--host <tailscale-host>] [--rw|--admin] [--dry-run]";
const input = {
  name: arg("--name") ?? "",
  rw: __f["--rw"] === true,
  admin: __f["--admin"] === true,
  host: arg("--host"),
  envLocal: arg("--env-local"),
  dryRun: __f["--dry-run"] === true,
};
// 기존 문구·종료코드 보존 — 이름 형식 불량은 usage 한 줄(구판 동일 판정: RESOURCE_NAME_RE),
// 나머지(상호배타·F2)는 엔진 술어 문구를 전용 메시지로. 전부 exit 2. (술어 문구 접두 매칭으로
// 분기하면 술어 개정 시 usage 경로가 조용히 사라진다 — 리뷰 지적으로 명시 판정 유지.)
if (!input.name || !RESOURCE_NAME_RE.test(input.name)) { console.error(USAGE); process.exit(2); }
const bad = dbUrlInputError(input);
if (bad !== null) {
  console.error(`db-url: ${bad}`);
  process.exit(2);
}
const { variant, result } = runDbUrl(input);
if (result.dryRun) {
  // 계획 JSON — 기존 필드 구성·순서 보존(평문 없음).
  console.log(JSON.stringify({ mode: result.mode, name: result.name, secretRef: result.secretRef, envKey: result.envKey, envFile: result.envFile, note: result.note }, null, 2));
  process.exit(0);
}
if (variant === "failure") {
  console.error(`db-url: ${result.error}`);
  process.exit(1);
}
console.log(`db-url: ${result.envFile}에 ${result.envKey} 기록(mode=${result.mode}, host=tailscale) — 값은 출력하지 않음`);
