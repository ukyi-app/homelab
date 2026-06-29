// db:url — 로컬/GUI 디버깅용 DB 연결 URL을 .env.local(admin은 .env.admin.local)에 기록한다.
// 모드(상호배타): 기본=RO(db-<name>-ro-conn, 읽기전용 롤) / --rw=owner(db-<name>-conn, 읽기쓰기) /
//   --admin=superuser(pg-admin-credentials, database ns — GUI 전용).
// "비파괴"는 도구가 보장 못 한다 — tailscale ACL은 *누가* 붙는지만, 롤 GRANT가 *무엇을*. 그래서 기본은 ro.
// 출력 키는 prod conn 핸들과 동일하게 namespaced — RW=<NAME>_DATABASE_URL, RO=<NAME>_RO_DATABASE_URL
//   (db-<name>-conn / db-<name>-ro-conn의 키와 일치 → 앱이 로컬·prod에서 같은 env 키를 읽는다).
// ★채널 분리(F2): RO/RW는 .env.local(앱 런타임 채널). admin은 <NAME>_DATABASE_ADMIN_URL
//   → .env.admin.local(앱 런타임/봉인 경로와 분리) — superuser URL이 실수로 앱 구동/봉인에 들어가지 않게.
//   .env.local·.env.admin.local은 .gitignore 필수, secret:seal 대상 아님(앱 봉인은 .env만).
// 평문 URL은 stdout에 절대 출력하지 않는다(전 모드). dry-run은 모드/secretRef/키/대상파일만(값 없음).
// 이 도구는 reset/drop 등 파괴 수단을 제공하지 않는다(파괴는 docker 모드 전용).
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { RESOURCE_NAME_RE } from "./lib/identity.ts";
import { parseFlags } from "./lib/cli.ts";

// parseFlags: unknown 옵션 + arg 삼킴 fail-closed. 종료 코드 2 보존.
let __f: Record<string, string | boolean>;
try { __f = parseFlags(process.argv.slice(2), { value: ["--name", "--host", "--env-local"], bool: ["--dry-run", "--rw", "--admin"] }); }
catch (e) { console.error(`db-url: ${e instanceof Error ? e.message : String(e)} (읽기 전용 도구 — 파괴 수단 없음)`); process.exit(2); }
const arg = (k: string, d?: string) => (typeof __f[k] === "string" ? __f[k] as string : d);
const DRY = __f["--dry-run"] === true;
const RW = __f["--rw"] === true;
const ADMIN = __f["--admin"] === true;
const name = arg("--name");
const tsHost = arg("--host", process.env.TS_DB_HOST ?? "");
if (!name || !RESOURCE_NAME_RE.test(name)) {
  console.error("usage: db-url --name <db> [--host <tailscale-host>] [--rw|--admin] [--dry-run]");
  process.exit(2);
}
if (RW && ADMIN) { console.error("db-url: --rw와 --admin은 상호배타 — 하나만 지정"); process.exit(2); }

const NAME = name.replaceAll("-", "_").toUpperCase();
// 모드별: secret(NS) · 내부 srcKey(있으면 URL, 없으면 basic-auth=admin) · 출력 env 키 · 대상 파일
const mode = ADMIN
  ? { label: "admin-superuser", ns: "database", secret: "pg-admin-credentials", srcKey: "", envKey: `${NAME}_DATABASE_ADMIN_URL`, envFile: ".env.admin.local" }
  : RW
    ? { label: "owner-readwrite", ns: "prod", secret: `db-${name}-conn`, srcKey: `${NAME}_DATABASE_URL`, envKey: `${NAME}_DATABASE_URL`, envFile: ".env.local" }
    : { label: "readonly", ns: "prod", secret: `db-${name}-ro-conn`, srcKey: `${NAME}_RO_DATABASE_URL`, envKey: `${NAME}_RO_DATABASE_URL`, envFile: ".env.local" };
const envLocal = arg("--env-local", mode.envFile)!;
// F2 채널 분리 완결: --admin은 .env.admin.local에만 기록 — --env-local로 앱 런타임 파일(.env.local 등)을
// 가리켜 superuser URL을 런타임 채널에 흘리는 것을 차단한다(envKey는 namespaced <NAME>_DATABASE_ADMIN_URL이라
// 앱 런타임 키와 겹치지 않지만 파일 분리 불변식도 강제).
if (ADMIN && typeof __f["--env-local"] === "string" && envLocal !== mode.envFile) {
  console.error(`db-url: --admin은 ${mode.envFile}에만 기록 — --env-local로 앱 런타임 파일 지정 불가(F2 채널 분리)`);
  process.exit(2);
}

if (DRY) {
  console.log(JSON.stringify({
    mode: mode.label, name, secretRef: `${mode.ns}/${mode.secret}`,
    envKey: mode.envKey, envFile: envLocal,
    note: "평문 URL은 stdout에 출력하지 않음 — 라이브 실행 시 host를 tailscale로 치환해 대상 파일에만 기록",
  }, null, 2));
  process.exit(0);
}

if (!tsHost) {
  console.error("db-url: --host <tailscale-host>(또는 TS_DB_HOST) 필요 — pg-rw-tailscale LB host(런북)");
  process.exit(1);
}

// 라이브: secret에서 자격을 꺼내 host를 tailscale로 치환(admin은 basic-auth로 URL 조립). 값은 stdout 비노출.
const b64 = (s: string) => Buffer.from(s, "base64").toString("utf8");
const getData = (key: string) => execFileSync("kubectl",
  ["-n", mode.ns, "get", "secret", mode.secret, "-o", `jsonpath={.data.${key}}`], { encoding: "utf8" });
let url: string;
if (ADMIN) {
  const user = b64(getData("username"));
  const pw = b64(getData("password"));
  url = `postgres://${encodeURIComponent(user)}:${encodeURIComponent(pw)}@${tsHost}:5432/${name}`;
} else {
  url = b64(getData(mode.srcKey)).replace(/@[^/]+\//, `@${tsHost}:5432/`);
}
const lines = existsSync(envLocal) ? readFileSync(envLocal, "utf8").split("\n").filter((l) => !l.startsWith(`${mode.envKey}=`)) : [];
lines.push(`${mode.envKey}=${url}`);
writeFileSync(envLocal, lines.filter(Boolean).join("\n") + "\n");
console.log(`db-url: ${envLocal}에 ${mode.envKey} 기록(mode=${mode.label}, host=tailscale) — 값은 출력하지 않음`);
