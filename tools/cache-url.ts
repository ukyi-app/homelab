// cache:url — 로컬/GUI 디버깅용 Valkey 연결 URL을 .env.local에 기록한다. db-url과 대칭.
// 모드: 기본=RO(cache-<name>-ro-conn, 읽기 ACL 유저) / --rw=default 유저(cache-<name>-conn, 관리=RW).
//   Valkey는 per-instance라 별도 superuser 없음 — --rw의 default 유저가 최상위 권한(db-url --admin 무대응).
// ★F3(노출 정합): Valkey tailscale 상시 노출은 deferred(캐시별 Service/netpol/ACL 비용) — 따라서 host는
//   tailscale가 아니라 **127.0.0.1(port-forward 타깃)** 기본. 선행: kubectl -n cache port-forward
//   svc/<name> 6379:6379 (런북). tailscale 상시 노출이 필요하면 별도 PR(db-url처럼 LB+netpol+ACL).
// 출력 키는 prod conn 핸들과 동일하게 namespaced(RW=<NAME>_REDIS_URL, RO=<NAME>_REDIS_RO_URL) —
//   앱이 로컬·prod에서 같은 env 키를 읽는다. 평문 URL은 stdout에 절대 출력하지 않는다. 파괴 수단 없음.
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { RESOURCE_NAME_RE } from "./lib/identity.ts";
import { parseFlags } from "./lib/cli.ts";

// parseFlags: unknown 옵션 + arg 삼킴 fail-closed. 종료 코드 2 보존.
let __f: Record<string, string | boolean>;
try { __f = parseFlags(process.argv.slice(2), { value: ["--name", "--host", "--env-local"], bool: ["--dry-run", "--rw"] }); }
catch (e) { console.error(`cache-url: ${e instanceof Error ? e.message : String(e)} (읽기 전용 도구)`); process.exit(2); }
const arg = (k: string, d?: string) => (typeof __f[k] === "string" ? __f[k] as string : d);
const DRY = __f["--dry-run"] === true;
const RW = __f["--rw"] === true;
const name = arg("--name");
const host = arg("--host", process.env.CACHE_LOCAL_HOST ?? "127.0.0.1")!; // 기본 port-forward localhost
const envLocal = arg("--env-local", ".env.local")!;
if (!name || !RESOURCE_NAME_RE.test(name)) {
  console.error("usage: cache-url --name <cache> [--host <port-forward-host>] [--rw] [--dry-run]");
  process.exit(2);
}

const NAME = name.replaceAll("-", "_").toUpperCase();
const mode = RW
  ? { label: "default-readwrite", secret: `cache-${name}-conn`, srcKey: `${NAME}_REDIS_URL`, envKey: `${NAME}_REDIS_URL` }
  : { label: "readonly", secret: `cache-${name}-ro-conn`, srcKey: `${NAME}_REDIS_RO_URL`, envKey: `${NAME}_REDIS_RO_URL` };
const envKey = mode.envKey; // prod conn 핸들과 동일한 namespaced 키(RW=<NAME>_REDIS_URL, RO=<NAME>_REDIS_RO_URL)

if (DRY) {
  console.log(JSON.stringify({
    mode: mode.label, name, secretRef: `prod/${mode.secret}`, envKey, envFile: envLocal,
    host: `${host}:6379`,
    note: `Valkey tailscale 상시 노출은 deferred — 선행 kubectl -n cache port-forward svc/${name} 6379:6379. 평문 URL은 stdout에 출력하지 않음`,
  }, null, 2));
  process.exit(0);
}

// 라이브: prod NS의 conn에서 URL을 꺼내 host를 port-forward 타깃으로 치환. 값은 stdout 비노출.
const url = execFileSync("kubectl",
  ["-n", "prod", "get", "secret", mode.secret, "-o", `jsonpath={.data.${mode.srcKey}}`], { encoding: "utf8" });
const plain = Buffer.from(url, "base64").toString("utf8").replace(/@[^/]+/, `@${host}:6379`);
const lines = existsSync(envLocal) ? readFileSync(envLocal, "utf8").split("\n").filter((l) => !l.startsWith(`${envKey}=`)) : [];
lines.push(`${envKey}=${plain}`);
writeFileSync(envLocal, lines.filter(Boolean).join("\n") + "\n");
console.log(`cache-url: ${envLocal}에 ${envKey} 기록(mode=${mode.label}, host=port-forward) — 값은 출력하지 않음`);
