// 로컬 개발 진입점. 서브커맨드:
//   (없음)    : dev Postgres 기동 + 워크스페이스 dev 루프 (기존 동작)
//   db:up     : 모드 1(깨끗한 개발) — docker postgres 기동 + 시드. 파괴 OK.
//   db:reset  : 모드 1 초기화(volume 포함 내림 후 재기동).
// 모드 2(실데이터 읽기 전용)는 tools/db-url.ts / cache-url.ts — 파괴 수단 없음.
// 실행은 exec seam 경유(d6④) — 셸 문자열 대신 argv 배열(공백 경로에도 안전), stdio는 inherit로
// 종전 화면 출력을 유지한다. timeoutMs 0 = compose 풀/기동·dev 루프의 무제한 대기 보존.
import { sh } from "./lib/exec.ts";

const argv = process.argv.slice(2);
const cmd = argv[0]?.startsWith("--") ? undefined : argv[0];
const DRY = argv.includes("--dry-run");
const COMPOSE = ["compose", "-f", "tools/dev-postgres/compose.yaml"];
const compose = (...a: string[]) => {
  const r = sh("docker", [...COMPOSE, ...a], { inherit: true, timeoutMs: 0 });
  // spawn 자체 실패(docker 미설치 등)는 inherit로도 화면에 아무것도 안 나온다 — 종전 셸 경유가
  // 내던 "docker: not found" 화자를 seam의 errKind가 대신한다(무음 실패 금지).
  if (r.errKind !== undefined) { console.error(`dev: docker 실행 실패(${r.errKind}) — ${r.err}`); process.exit(1); }
  if (!r.ok) process.exit(r.status ?? 1); // 자식 rc를 그대로 전파(종전 execSync는 일괄 1 — 값 보존은 개선 방향)
};

if (cmd === "db:up" || cmd === "db:reset") {
  // canonical DATABASE_URL — db-url.ts(모드2)·클러스터 계약과 동일 변수명(설계 §5.7 로컬·클러스터 일치).
  // 모드1은 단일 docker dev DB(app_dev)라 per-name 구분 불요(--name은 더 이상 키에 영향 없음).
  const envKey = "DATABASE_URL";
  const url = "postgres://dev:dev@localhost:5432/app_dev";
  if (DRY) {
    console.log(JSON.stringify({ mode: "docker-clean-dev", cmd, [envKey]: url, note: ".env에 localhost URL — 파괴 작업은 이 모드에서만" }, null, 2));
    process.exit(0);
  }
  if (cmd === "db:reset") compose("down", "-v");
  compose("up", "-d", "--wait");
  console.log(`dev Postgres ready on localhost:5432 — .env: ${envKey}=${url}`);
  process.exit(0);
}

console.log("starting local dev Postgres (OrbStack docker)…");
compose("up", "-d", "--wait");
console.log("dev Postgres ready on localhost:5432 (db=app_dev user=dev).");

// 인-레포 앱(bun 워크스페이스 멤버)들의 dev 루프를 병렬 실행 — 현재 앱은 외부 레포라 멤버 0(no-op).
// 동기 fg 대기(inherit) — ^C(SIGINT)는 터미널 fg 프로세스 그룹 전체에 전달되므로 종전 spawn +
// p.kill(SIGINT) 중계와 같은 결말이다(부모가 먼저 죽고 자식이 남는 창이 오히려 사라진다).
const p = sh("bun", ["run", "--filter", "*", "dev"], { inherit: true, timeoutMs: 0 });
if (p.errKind !== undefined) { console.error(`dev: bun 실행 실패(${p.errKind}) — ${p.err}`); process.exit(1); }
process.exit(p.status ?? 0);
