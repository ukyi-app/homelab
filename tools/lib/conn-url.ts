// conn URL 엔진 — db url/cache url 동사의 실체(cli-deepening 심화 5). bin(db-url/cache-url)에
// 살던 로직의 lib 승격이다: 계획이 타입 값(UrlResult)이 되어 계획 키 드리프트(release r2-a5
// 실사고 클래스)가 스키마 위반 사후 검출에서 컴파일 타임 오류로 강등되고, CLI 셸과 MCP가
// 같은 op를 얇은 어댑터로 소비한다(status.ts 패턴 — 자식 프로세스 이중 실행·계획 화이트리스트
// 소멸). 기존 bin은 이 엔진 위의 껍데기로 존속한다(package.json db:url/cache:url 소비자 보존).
//
// 규율:
//   - 평문 비출력은 엔진 소유 — URL 값은 결과의 어떤 필드에도 담지 않는다(wrote 불리언만).
//     UrlResult는 urlResult 스키마 정의(additionalProperties:false)와 1:1 — 필드 추가는
//     기술자·생성기와 함께만.
//   - F2 채널 분리 — admin은 .env.admin.local 전용(입력 술어가 강제: superuser URL이 앱 런타임
//     채널로 새는 것 차단). rw/admin 상호배타도 술어 소유.
//   - envLocal·envDir 축은 엔진 입력에 존재하되 MCP inputSchema에는 envDir만 노출한다(설계 Q9 —
//     envLocal의 MCP 노출은 별도 신뢰 경계 결정으로 이연).
//   - conn 핸들·env 키는 레이아웃 커널(resource-layout) 소비 — 재유도 금지.
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { isAbsolute, join } from "node:path";
import { sh } from "./exec.ts";
import { RESOURCE_NAME_RE } from "./identity.ts";
import { layoutFor } from "./resource-layout.ts";

export type DbUrlInput = {
  name: string;
  rw?: boolean;
  admin?: boolean;
  host?: string;     // 미지정 = TS_DB_HOST 환경 변수(런북 규약)
  envLocal?: string; // 대상 파일 오버라이드(기본: 모드별 — admin은 F2로 오버라이드 금지)
  envDir?: string;   // 대상 파일의 기준 디렉토리(MCP 명시 입력 — 서버 cwd 추론 없음)
  dryRun?: boolean;
};
export type CacheUrlInput = {
  name: string;
  rw?: boolean;
  host?: string;     // 미지정 = CACHE_LOCAL_HOST 또는 127.0.0.1(port-forward 타깃)
  envLocal?: string;
  envDir?: string;
  dryRun?: boolean;
};

// urlResult 정의와 1:1(name·dryRun 필수, 나머지 선택) — 평문 URL 필드는 존재하지 않는다.
export type UrlResult = {
  name: string;
  mode?: string;
  secretRef?: string;
  envKey?: string;
  envFile?: string;
  note?: string;
  dryRun: boolean;
  wrote?: boolean;
  error?: string;
};
export type UrlOutcome = { variant: "success" | "failure"; omitted: string[]; result: UrlResult };

// 입력 검증 술어 — CLI(usage exit 2)·MCP(invalid params)·bin 껍데기가 공유.
export function dbUrlInputError(input: DbUrlInput): string | null {
  if (!input.name || !RESOURCE_NAME_RE.test(input.name)) return `이름 형식 불량(소문자 kebab, ≤30): ${input.name}`;
  if (input.rw === true && input.admin === true) return "--rw와 --admin은 상호배타 — 하나만 지정";
  // F2 채널 분리 완결 — admin은 .env.admin.local에만 기록(런타임 채널로 superuser URL 유출 차단).
  if (input.admin === true && input.envLocal !== undefined && input.envLocal !== ".env.admin.local") {
    return "--admin은 .env.admin.local에만 기록 — --env-local로 앱 런타임 파일 지정 불가(F2 채널 분리)";
  }
  return null;
}
export function cacheUrlInputError(input: CacheUrlInput): string | null {
  if (!input.name || !RESOURCE_NAME_RE.test(input.name)) return `이름 형식 불량(소문자 kebab, ≤30): ${input.name}`;
  return null;
}

type Mode = { label: string; ns: string; secret: string; srcKey: string; envKey: string; envFile: string };

// 모드 유도 — 핸들·키는 레이아웃 커널, admin은 커널 밖 별도 채널(pg superuser — F2·F3).
function dbMode(input: DbUrlInput): Mode {
  const L = layoutFor("db", input.name);
  const NAME = input.name.replaceAll("-", "_").toUpperCase(); // admin 키 전용(커널 밖 채널)
  if (input.admin === true) {
    return { label: "admin-superuser", ns: "database", secret: "pg-admin-credentials", srcKey: "", envKey: `${NAME}_DATABASE_ADMIN_URL`, envFile: ".env.admin.local" };
  }
  if (input.rw === true) {
    return { label: "owner-readwrite", ns: "prod", secret: L.handles.rw.name, srcKey: L.envKeys.rw, envKey: L.envKeys.rw, envFile: ".env.local" };
  }
  return { label: "readonly", ns: "prod", secret: L.handles.ro.name, srcKey: L.envKeys.ro, envKey: L.envKeys.ro, envFile: ".env.local" };
}

function cacheMode(input: CacheUrlInput): Mode {
  const L = layoutFor("cache", input.name);
  return input.rw === true
    ? { label: "default-readwrite", ns: "prod", secret: L.handles.rw.name, srcKey: L.envKeys.rw, envKey: L.envKeys.rw, envFile: ".env.local" }
    : { label: "readonly", ns: "prod", secret: L.handles.ro.name, srcKey: L.envKeys.ro, envKey: L.envKeys.ro, envFile: ".env.local" };
}

// env 파일 upsert — 같은 키 행만 교체, 값은 로그·결과에 비노출.
function upsertEnv(target: string, envKey: string, url: string): void {
  const lines = existsSync(target) ? readFileSync(target, "utf8").split("\n").filter((l) => !l.startsWith(`${envKey}=`)) : [];
  lines.push(`${envKey}=${url}`);
  writeFileSync(target, lines.filter(Boolean).join("\n") + "\n");
}

function targetPath(envFile: string, envDir: string | undefined): string {
  return isAbsolute(envFile) ? envFile : join(envDir ?? process.cwd(), envFile);
}

function kubectlData(ns: string, secret: string, key: string): { ok: boolean; value: string; err: string } {
  const r = sh("kubectl", ["-n", ns, "get", "secret", secret, "-o", `jsonpath={.data.${key}}`]);
  return r.ok
    ? { ok: true, value: Buffer.from(r.out, "base64").toString("utf8"), err: "" }
    : { ok: false, value: "", err: r.err.split("\n")[0] || "kubectl 실패" };
}

export function runDbUrl(input: DbUrlInput): UrlOutcome {
  const mode = dbMode(input);
  const envFile = input.envLocal ?? mode.envFile;
  const base: UrlResult = { name: input.name, mode: mode.label, secretRef: `${mode.ns}/${mode.secret}`, envKey: mode.envKey, envFile, dryRun: input.dryRun === true };
  const failure = (error: string): UrlOutcome => ({ variant: "failure", omitted: [], result: { ...base, wrote: false, error } });
  if (input.dryRun === true) {
    return { variant: "success", omitted: [], result: { ...base, wrote: false, note: "평문 URL은 stdout에 출력하지 않음 — 라이브 실행 시 host를 tailscale로 치환해 대상 파일에만 기록" } };
  }
  const tsHost = input.host ?? process.env.TS_DB_HOST ?? "";
  if (tsHost === "") return failure("--host <tailscale-host>(또는 TS_DB_HOST) 필요 — pg-rw-tailscale LB host(런북)");
  let url: string;
  if (input.admin === true) {
    const user = kubectlData(mode.ns, mode.secret, "username");
    const pw = kubectlData(mode.ns, mode.secret, "password");
    if (!user.ok || !pw.ok) return failure(user.err || pw.err);
    url = `postgres://${encodeURIComponent(user.value)}:${encodeURIComponent(pw.value)}@${tsHost}:5432/${input.name}`;
  } else {
    const src = kubectlData(mode.ns, mode.secret, mode.srcKey);
    if (!src.ok) return failure(src.err);
    url = src.value.replace(/@[^/]+\//, `@${tsHost}:5432/`);
  }
  try { upsertEnv(targetPath(envFile, input.envDir), mode.envKey, url); }
  catch (e) { return failure(e instanceof Error ? e.message : String(e)); }
  return { variant: "success", omitted: [], result: { ...base, wrote: true } };
}

export function runCacheUrl(input: CacheUrlInput): UrlOutcome {
  const mode = cacheMode(input);
  const envFile = input.envLocal ?? mode.envFile;
  const host = input.host ?? process.env.CACHE_LOCAL_HOST ?? "127.0.0.1"; // 기본 port-forward localhost
  const base: UrlResult = { name: input.name, mode: mode.label, secretRef: `${mode.ns}/${mode.secret}`, envKey: mode.envKey, envFile, dryRun: input.dryRun === true };
  const failure = (error: string): UrlOutcome => ({ variant: "failure", omitted: [], result: { ...base, wrote: false, error } });
  if (input.dryRun === true) {
    return { variant: "success", omitted: [], result: { ...base, wrote: false, note: `Valkey tailscale 상시 노출은 deferred — 선행 kubectl -n cache port-forward svc/${input.name} 6379:6379. 평문 URL은 stdout에 출력하지 않음` } };
  }
  const src = kubectlData(mode.ns, mode.secret, mode.srcKey);
  if (!src.ok) return failure(src.err);
  const url = src.value.replace(/@[^/]+/, `@${host}:6379`);
  try { upsertEnv(targetPath(envFile, input.envDir), mode.envKey, url); }
  catch (e) { return failure(e instanceof Error ? e.message : String(e)); }
  return { variant: "success", omitted: [], result: { ...base, wrote: true } };
}
