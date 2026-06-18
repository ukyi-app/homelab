// 로컬 개발 진입점. 서브커맨드:
//   (없음)    : dev Postgres 기동 + 워크스페이스 dev 루프 (기존 동작)
//   db:up     : 모드 1(깨끗한 개발) — docker postgres 기동 + 시드. 파괴 OK.
//   db:reset  : 모드 1 초기화(volume 포함 내림 후 재기동).
// 모드 2(실데이터 읽기 전용)는 tools/db-url.ts / cache-url.ts — 파괴 수단 없음.
import { execSync, spawn } from "node:child_process";

const argv = process.argv.slice(2);
const cmd = argv[0]?.startsWith("--") ? undefined : argv[0];
const arg = (k: string, d?: string) => { const i = argv.indexOf(k); return i > -1 ? argv[i + 1] : d; };
const DRY = argv.includes("--dry-run");
const COMPOSE = "docker compose -f tools/dev-postgres/compose.yaml";

if (cmd === "db:up" || cmd === "db:reset") {
  const name = arg("--name", "app")!;
  const envKey = `${name.replaceAll("-", "_").toUpperCase()}_DATABASE_URL`;
  const url = "postgres://dev:dev@localhost:5432/app_dev";
  if (DRY) {
    console.log(JSON.stringify({ mode: "docker-clean-dev", cmd, [envKey]: url, note: ".env에 localhost URL — 파괴 작업은 이 모드에서만" }, null, 2));
    process.exit(0);
  }
  if (cmd === "db:reset") execSync(`${COMPOSE} down -v`, { stdio: "inherit" });
  execSync(`${COMPOSE} up -d --wait`, { stdio: "inherit" });
  console.log(`dev Postgres ready on localhost:5432 — .env: ${envKey}=${url}`);
  process.exit(0);
}

console.log("starting local dev Postgres (OrbStack docker)…");
execSync(`${COMPOSE} up -d --wait`, { stdio: "inherit" });
console.log("dev Postgres ready on localhost:5432 (db=app_dev user=dev).");

// 인-레포 앱(bun 워크스페이스 멤버)들의 dev 루프를 병렬 실행 — 현재 앱은 외부 레포라 멤버 0(no-op).
const p = spawn("bun", ["run", "--filter", "*", "dev"], { stdio: "inherit" });
process.on("SIGINT", () => { p.kill("SIGINT"); });
