// db:url — 모드 2(실데이터 디버깅): 클러스터 DB에 tailscale로 **읽기 전용** 직결.
// "단방향/비파괴"는 경고로 보장되지 않는다 — tailscale ACL은 *누가* 붙는지만 제어하고
// *어떤 SQL*은 못 막는다. 그래서 owner가 아니라 **<name>_ro 롤 자격**(GRANT SELECT only)을
// prod의 db-<name>-ro-conn Secret에서 꺼내 .env.local에 기록한다.
// 이 도구는 reset/drop 등 어떤 파괴 수단도 제공하지 않는다(파괴 작업은 docker 모드 전용).
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { execFileSync } from "node:child_process";

const arg = (k: string, d?: string) => { const i = process.argv.indexOf(k); return i > -1 ? process.argv[i + 1] : d; };
const DRY = process.argv.includes("--dry-run");
const name = arg("--name");
const tsHost = arg("--host", process.env.TS_DB_HOST ?? "");
const envLocal = arg("--env-local", ".env.local")!;

const allowed = new Set(["--name", "--host", "--env-local", "--dry-run"]);
for (const a of process.argv.slice(2)) {
  if (a.startsWith("--") && !allowed.has(a)) {
    console.error(`db-url: 지원하지 않는 옵션: ${a} (읽기 전용 도구 — 파괴 수단 없음)`);
    process.exit(2);
  }
}
if (!name || !/^[a-z][a-z0-9-]*$/.test(name)) {
  console.error("usage: db-url --name <db> [--host <tailscale-ip>] [--dry-run]");
  process.exit(2);
}

const envKey = `${name.replaceAll("-", "_").toUpperCase()}_DATABASE_URL`;
const roUser = `${name.replaceAll("-", "_")}_ro`;

if (DRY) {
  console.log(JSON.stringify({
    mode: "tailscale-readonly",
    name, user: roUser, envKey,
    note: "prod의 db-<name>-ro-conn에서 ro 자격을 꺼내 host를 tailscale IP로 치환해 .env.local에 기록",
  }, null, 2));
  process.exit(0);
}

if (!tsHost) {
  console.error("db-url: --host <tailscale-ip>(또는 TS_DB_HOST) 필요 — 리소스를 tailscale LB로 노출했을 때만(런북)");
  process.exit(1);
}
// 라이브: prod NS의 ro conn에서 URL을 꺼내 host만 tailscale IP로 치환 (값은 stdout 비노출)
const url = execFileSync("kubectl", [
  "-n", "prod", "get", "secret", `db-${name}-ro-conn`,
  "-o", `jsonpath={.data.${name.replaceAll("-", "_").toUpperCase()}_RO_DATABASE_URL}`,
], { encoding: "utf8" });
const plain = Buffer.from(url, "base64").toString("utf8")
  .replace(/@[^/]+\//, `@${tsHost}:5432/`);
const lines = existsSync(envLocal) ? readFileSync(envLocal, "utf8").split("\n").filter((l) => !l.startsWith(`${envKey}=`)) : [];
lines.push(`${envKey}=${plain}`);
writeFileSync(envLocal, lines.filter(Boolean).join("\n") + "\n");
console.log(`db-url: ${envLocal}에 ${envKey} 기록(user=${roUser}, host=tailscale) — 값은 출력하지 않음`);
