// pg-tools 인라인 digest 재핀 — 5개 소비처(4파일)의 pg-tools:18-rclone@sha256 핀을 새 digest로.
// bump.yaml이 build 완료 후 호출(기존 apps/ 스킵 로직 대체). digest는 형식 검증. 멱등(불변 시 no-op).
import { readFileSync, writeFileSync } from "node:fs";

const CONSUMERS = [
  "platform/cache/prod/backup-cronjob.yaml", // init+main 2-site
  "platform/cnpg/prod/ensure-role-password-job.yaml",
  "platform/cnpg/prod/restore-drill-cronjob.yaml",
  "platform/cnpg/prod/pgdump-hedge-cronjob.yaml",
] as const;
const REF = /(ghcr\.io\/[a-z0-9-]+\/pg-tools:18-rclone@)sha256:[0-9a-f]{64}/g;

const argv = process.argv.slice(2);
const rootIdx = argv.indexOf("--root");
const root = rootIdx >= 0 ? argv[rootIdx + 1] : ".";
const digest = argv.find((a) => !a.startsWith("--") && a !== root);
if (!/^sha256:[0-9a-f]{64}$/.test(digest ?? "")) {
  console.error(`bad digest: ${digest ?? "<none>"}`);
  process.exit(2);
}
let changed = 0;
for (const rel of CONSUMERS) {
  const f = `${root}/${rel}`;
  const cur = readFileSync(f, "utf8");
  const next = cur.replace(REF, `$1${digest}`);
  if (next !== cur) {
    writeFileSync(f, next);
    changed++;
    console.log(`repin: ${rel}`);
  }
}
console.log(changed ? `repin: ${changed}/${CONSUMERS.length} 파일 갱신 (${digest})` : `repin: 이미 ${digest} (no-op)`);
