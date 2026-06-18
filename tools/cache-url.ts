// cache:url — 모드 2: Valkey에 tailscale로 읽기 전용 직결(+@read -@write -@dangerous ACL 유저).
// db-url.ts와 대칭 — 파괴 수단 없음.
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { execFileSync } from "node:child_process";

const arg = (k: string, d?: string) => { const i = process.argv.indexOf(k); return i > -1 ? process.argv[i + 1] : d; };
const DRY = process.argv.includes("--dry-run");
const name = arg("--name");
const tsHost = arg("--host", process.env.TS_CACHE_HOST ?? "");
const envLocal = arg("--env-local", ".env.local")!;

const allowed = new Set(["--name", "--host", "--env-local", "--dry-run"]);
for (const a of process.argv.slice(2)) {
  if (a.startsWith("--") && !allowed.has(a)) {
    console.error(`cache-url: 지원하지 않는 옵션: ${a} (읽기 전용 도구)`);
    process.exit(2);
  }
}
if (!name || !/^[a-z][a-z0-9-]*$/.test(name)) {
  console.error("usage: cache-url --name <cache> [--host <tailscale-ip>] [--dry-run]");
  process.exit(2);
}

const NAME = name.replaceAll("-", "_").toUpperCase();
// ro-conn Secret의 내부 키는 <NAME>_REDIS_RO_URL(읽기 ACL 유저). 앱이 소비하는 .env.local
// 키는 <NAME>_REDIS_URL — 디버깅 시 그 키가 tailscale 직결 ro 엔드포인트를 가리키게 한다
// (db-url과 동일 규약: ro 키를 읽어 비-ro 소비 키로 기록).
const roEnvKey = `${NAME}_REDIS_RO_URL`;
const envKey = `${NAME}_REDIS_URL`;

if (DRY) {
  console.log(JSON.stringify({
    mode: "tailscale-readonly",
    name, conn: `cache-${name}-ro-conn`, roEnvKey, envKey,
    note: "prod의 cache-<name>-ro-conn(읽기 ACL 유저)에서 자격을 꺼내 .env.local에 기록",
  }, null, 2));
  process.exit(0);
}

if (!tsHost) {
  console.error("cache-url: --host <tailscale-ip>(또는 TS_CACHE_HOST) 필요");
  process.exit(1);
}
const url = execFileSync("kubectl", [
  "-n", "prod", "get", "secret", `cache-${name}-ro-conn`,
  "-o", `jsonpath={.data.${roEnvKey}}`,
], { encoding: "utf8" });
const plain = Buffer.from(url, "base64").toString("utf8")
  .replace(/@[^/]+/, `@${tsHost}:6379`);
const lines = existsSync(envLocal) ? readFileSync(envLocal, "utf8").split("\n").filter((l) => !l.startsWith(`${envKey}=`)) : [];
lines.push(`${envKey}=${plain}`);
writeFileSync(envLocal, lines.filter(Boolean).join("\n") + "\n");
console.log(`cache-url: ${envLocal}에 ${envKey} 기록 — 값은 출력하지 않음`);
