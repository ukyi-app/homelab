// env:example — .app-config.yml(env+secrets+db+redis)에서 .env.example을 생성한다.
// 로컬 패리티: 개발자가 어떤 env 키를 채워야 하는지 계약에서 자동 유도(값은 비움/플레이스홀더).
import { readFileSync, writeFileSync } from "node:fs";
import { parse } from "yaml";

const arg = (k, d) => { const i = process.argv.indexOf(k); return i > -1 ? process.argv[i + 1] : d; };
const configPath = arg("--config", ".app-config.yml");
const out = arg("--out", ".env.example");

const config = parse(readFileSync(configPath, "utf8")) ?? {};
const upper = (n) => n.replaceAll("-", "_").toUpperCase();

const lines = ["# .app-config.yml에서 자동 생성 (pnpm env:example) — 값을 채워 .env로 복사"];
for (const e of config.env ?? []) lines.push(`${e.name}=${e.value}`);
for (const s of config.secrets ?? []) lines.push(`${upper(s)}=`);
for (const d of config.db ?? []) lines.push(`${upper(d)}_DATABASE_URL=postgres://dev:dev@localhost:5432/app_dev`);
for (const r of config.redis ?? []) lines.push(`${upper(r)}_REDIS_URL=redis://localhost:6379`);
writeFileSync(out, lines.join("\n") + "\n");
console.log(`env-example: ${out} 생성 (${lines.length - 1}키)`);
