// cache:url — conn URL 엔진(lib/conn-url.ts)의 CLI 껍데기(cli-deepening 심화 5). db-url과 대칭.
// 접속 로직·평문 비출력은 엔진 소유 — 여기는 argv 파싱과 기존 출력 계약(dry-run 계획 JSON·기록
// 한 줄·종료코드 0/1/2, skip=4는 헬퍼 경유)만 보존한다. host 기본은 127.0.0.1(port-forward 타깃 — F3: tailscale 상시
// 노출은 deferred). homelab CLI(`homelab cache url`)와 MCP(cache_url)는 catalog op로 같은 엔진 소비.
import { cacheUrlInputError, runCacheUrl } from "./lib/conn-url.ts";
import { parseFlags, skip } from "./lib/cli.ts";

// parseFlags: unknown 옵션 + arg 삼킴 fail-closed. 종료 코드 2 보존.
let __f: Record<string, string | boolean>;
try { __f = parseFlags(process.argv.slice(2), { value: ["--name", "--host", "--env-local"], bool: ["--dry-run", "--rw"] }); }
catch (e) { console.error(`cache-url: ${e instanceof Error ? e.message : String(e)} (읽기 전용 도구)`); process.exit(2); }
const arg = (k: string) => (typeof __f[k] === "string" ? __f[k] as string : undefined);
const USAGE = "usage: cache-url --name <cache> [--host <port-forward-host>] [--rw] [--dry-run]";
const input = {
  name: arg("--name") ?? "",
  rw: __f["--rw"] === true,
  host: arg("--host"),
  envLocal: arg("--env-local"),
  dryRun: __f["--dry-run"] === true,
};
const bad = cacheUrlInputError(input);
if (bad !== null) { console.error(USAGE); process.exit(2); }
const { variant, result } = runCacheUrl(input);
if (result.dryRun) {
  // 계획 JSON — 기존 필드 구성·순서 보존. host 표기는 표시 전용(실값 유도는 엔진 소유와 동일 규약).
  const host = input.host ?? process.env.CACHE_LOCAL_HOST ?? "127.0.0.1";
  console.log(JSON.stringify({ mode: result.mode, name: result.name, secretRef: result.secretRef, envKey: result.envKey, envFile: result.envFile, host: `${host}:6379`, note: result.note }, null, 2));
  process.exit(0);
}
if (variant === "failure") {
  console.error(`cache-url: ${result.error}`);
  process.exit(1);
}
// 클러스터 도메인 부재 — 성공 문구를 내면 "기록했다"는 거짓말이 된다. 신호는 헬퍼 경유(4=skip
// 규약 — 가드형: 마커는 stdout이고, stderr 계약 마커는 homelab CLI 전용이다).
if (variant === "skip") skip("cache-url", result.note ?? "사유 미기록");
console.log(`cache-url: ${result.envFile}에 ${result.envKey} 기록(mode=${result.mode}, host=port-forward) — 값은 출력하지 않음`);
