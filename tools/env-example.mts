// env:example — .app-config.yml(secrets)에서 .env.example을 생성한다.
// 로컬 패리티: 개발자가 어떤 env 키를 채워야 하는지 계약에서 자동 유도(값은 비움/플레이스홀더).
// 연결(DB/Redis) URL은 앱 SealedSecret이라 여기 스캐폴드하지 않는다(로컬은 db-url/cache-url 도구로 .env.local 생성).
import { readFileSync, writeFileSync } from "node:fs";
import { parse } from "yaml";

const arg = (k: string, d: string) => { const i = process.argv.indexOf(k); return i > -1 ? process.argv[i + 1] : d; };
const configPath = arg("--config", ".app-config.yml");
const out = arg("--out", ".env.example");

const config = parse(readFileSync(configPath, "utf8")) ?? {};
const upper = (n: string) => n.replaceAll("-", "_").toUpperCase();

const lines = ["# .app-config.yml에서 자동 생성 (pnpm env:example) — 값을 채워 .env로 복사"];
for (const s of config.secrets ?? []) lines.push(`${upper(s)}=`);
writeFileSync(out, lines.join("\n") + "\n");
console.log(`env-example: ${out} 생성 (${lines.length - 1}키)`);
