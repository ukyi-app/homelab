// conn URL 엔진 — db url/cache url 동사의 실체. bin(db-url/cache-url)에
// 살던 로직의 lib 승격이다: 계획이 타입 값(UrlResult)이 되어 계획 키 드리프트(실사고
// 클래스)가 스키마 위반 사후 검출에서 컴파일 타임 오류로 강등되고, CLI 셸과 MCP가
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
//   - host 입력(--host·TS_DB_HOST·CACHE_LOCAL_HOST)은 hostError 술어를 지나야 URL·.env 행에 보간된다
//     (개행 하나로 .env.local에 임의 행이 주입되고 success가 났다). 치환은 정규식이 아니라
//     WHATWG URL host setter(userinfo 보존), 쓰기 seam은 개행을 2차로 막고 신규 파일은 0600이다.
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { isAbsolute, join } from "node:path";
import { sh } from "./exec.ts";
import { RESOURCE_NAME_RE, pathInputError } from "./identity.ts";
import { layoutFor } from "./resource-layout.ts";

export type DbUrlInput = {
  name: string;
  rw?: boolean;
  admin?: boolean;
  host?: string;     // 미지정 = TS_DB_HOST 환경 변수(런북 db-cache-access.md 규약)
  envLocal?: string; // 대상 파일 오버라이드(기본: 모드별 — admin은 F2로 오버라이드 금지)
  envDir?: string;   // 대상 파일의 기준 디렉토리(MCP 명시 입력 — 서버 cwd 추론 없음)
  dryRun?: boolean;
};
export type CacheUrlInput = {
  name: string;
  rw?: boolean;
  host?: string;     // 미지정 = CACHE_LOCAL_HOST 또는 127.0.0.1(port-forward 타깃 — 런북 db-cache-access.md)
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
// skip: 클러스터 도메인 부재(KUBECONFIG 미설정) — '평가했고 실패(failure)'가 아니라 '평가하지
// 않음'이다(가드 어휘의 4와 같은 선 — status.ts는 같은 조건을 omitted로 구별하지만 url 동사는
// 클러스터 조회가 본체라 부분 생략이 성립하지 않는다). 사유는 note가 담고, CLI 셸이 그 note로
// stderr 마커를 만든다(계약 x-contract.exitRationale). 설정됐는데 깨진 조회는 여전히 failure
// (doctor 선례: 미설정=warn·깨진 설정=fail) — **키 부재(빈 출력·rc 0)도 그 failure에 든다**
// (kubectl jsonpath가 키 부재를 rc 0으로 접으므로 rc만 보면 빈 자격 URL이 success로 기록된다).
export type UrlOutcome = { variant: "success" | "failure" | "skip"; omitted: string[]; result: UrlResult };

// host 술어 — **화이트리스트가 아니라 URL 구조를 깨는 문자의 거부**다. 화이트리스트(`[A-Za-z0-9.-]`류)는
// 밑줄 호스트명·후행점 FQDN 같은 정당한 라이브 입력을 막는다(tailscale MagicDNS 이름·LAN 이름·100.99.0.1은
// 통과해야 한다). 거부 집합: 공백·제어문자(개행 = .env 행 주입), `/ ? #`(경로·쿼리·프래그먼트 경계),
// `@`(userinfo 재배선), `:`(포트는 엔진이 붙인다), `[ ]`(IPv6 리터럴 외), `$ &`(String.replace 메타·쿼리 구분),
// `% \ < > ^ | " ' \``(WHATWG forbidden host code point 또는 셸 인용 사고 표면). IPv6는 `[hex:.]`만 통째로 예외.
// ⚠️ `new URL`의 host setter가 술어를 대신하지 못한다(bun 실측): 개행은 **조용히 제거**되고(`a\nb`→`ab`),
//    비특수 스킴의 opaque host라 `$ &`는 그대로 통과한다. 그래서 술어가 상류에 서고 쓰기 seam이 2차다.
const HOST_REJECT_RE = /[\s\x00-\x1f\x7f/?#@:[\]$&%\\<>^|"'`]/;
const IPV6_LITERAL_RE = /^\[[0-9A-Fa-f:.]+\]$/;
export function hostError(host: string): string | null {
  if (host === "") return "host가 비어 있다";
  if (IPV6_LITERAL_RE.test(host)) return null;
  if (HOST_REJECT_RE.test(host)) return `host 형식 불량(URL 구조를 깨는 문자 — 공백·제어문자·/?#@:[]$&%\\<>^|따옴표 금지, IPv6는 [..] 표기): ${JSON.stringify(host)}`;
  return null;
}

// 입력 검증 술어 — CLI(usage exit 2)·MCP(invalid params)·bin 껍데기가 공유. host는 명시 입력만 여기서
// 재고(env 폴백은 run* 안에서 같은 술어로 failure) — `undefined`는 폴백 경로라 통과시킨다.
export function dbUrlInputError(input: DbUrlInput): string | null {
  if (!input.name || !RESOURCE_NAME_RE.test(input.name)) return `이름 형식 불량(소문자 kebab, ≤30): ${input.name}`;
  if (input.host !== undefined) { const he = hostError(input.host); if (he !== null) return `--host ${he}`; }
  // 명시 envDir(MCP)만 절대성을 잰다 — undefined는 process.cwd() 기준(CLI)이라 통과(identity.pathInputError 주석).
  if (input.envDir !== undefined) { const pe = pathInputError("envDir", input.envDir); if (pe !== null) return pe; }
  if (input.rw === true && input.admin === true) return "--rw와 --admin은 상호배타 — 하나만 지정";
  // F2 채널 분리 완결 — admin은 .env.admin.local에만 기록(런타임 채널로 superuser URL 유출 차단).
  if (input.admin === true && input.envLocal !== undefined && input.envLocal !== ".env.admin.local") {
    return "--admin은 .env.admin.local에만 기록 — --env-local로 앱 런타임 파일 지정 불가(F2 채널 분리)";
  }
  return null;
}
export function cacheUrlInputError(input: CacheUrlInput): string | null {
  if (!input.name || !RESOURCE_NAME_RE.test(input.name)) return `이름 형식 불량(소문자 kebab, ≤30): ${input.name}`;
  if (input.host !== undefined) { const he = hostError(input.host); if (he !== null) return `--host ${he}`; }
  if (input.envDir !== undefined) { const pe = pathInputError("envDir", input.envDir); if (pe !== null) return pe; }
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
// 쓰기 seam의 **1차 방어**: 값에 개행이 있으면 .env 파일에 임의 행이 주입된다 — db/cache·ro/rw/admin·
// --host/env 폴백 어느 경로든 이 한 지점을 지나므로 여기서 throw한다(콜사이트 try/catch가 failure·
// wrote:false로 접는다). host 술어는 상류의 2차이고, URL setter는 개행을 조용히 지우므로 여기가 마지막 선이다.
// 신규 생성 파일만 0600 — superuser URL(admin)이 같은 호스트의 다른 사용자에게 읽히지 않게. mode는 O_CREAT
// 시점에만 적용되므로 기존 파일의 퍼미션은 건드리지 않는다(사용자 파일 퍼미션 존중 — chmod 안 함).
// ⚠️ **중복 제거의 판정 조건은 '키 행이 1개'가 아니라 '옛 자격 문자열이 파일에 0회'다**.
// 접두 정확 일치(`KEY=`)만 지우면 dotenv가 똑같이 읽는 `export KEY=`·`KEY = ` 행이 살아남아 새 행과
// 공존하고, 어느 값이 이기는지가 로더 구현에 달린다 — 회전한 자격이 파일에 남는 것 자체가 결함이다.
// 빈 줄·주석은 **사용자의 구조**라 보존한다(종전 `.filter(Boolean)`이 빈 줄을 전부 지웠다).
function upsertEnv(target: string, envKey: string, url: string): void {
  if (/[\r\n]/.test(url) || /[\r\n]/.test(envKey)) throw new Error("env 값에 개행이 있다 — .env 행 주입 차단(기록 안 함)");
  // envKey는 레이아웃 커널 산출([A-Z0-9_])이지만 정규식 문맥에 넣으므로 방어적으로 이스케이프한다.
  const dup = new RegExp(`^[ \\t]*(export[ \\t]+)?${envKey.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}[ \\t]*=`);
  const prev = existsSync(target) ? readFileSync(target, "utf8") : "";
  const lines = prev === "" ? [] : prev.split("\n").filter((l) => !dup.test(l));
  while (lines.length > 0 && lines[lines.length - 1] === "") lines.pop(); // 말미 개행만 정규화
  lines.push(`${envKey}=${url}`);
  writeFileSync(target, lines.join("\n") + "\n", { mode: 0o600 });
}

// 기록 대상이 git이 무시하는 경로인가 — 아니면 note에 경고를 싣는다(variant는 success 유지: 관측
// 편의지 거부 사유가 아니다). `--env-local local.env` 같은 임의 파일명과 **앱 레포의 .gitignore**는
// 이 레포의 통제 밖이라 정적으로 알 수 없다. git 부재·판정 실패는 **침묵**한다 — 모르는 것을 근거로
// "안전하다"고도 "위험하다"고도 말하지 않는다(경고는 알 때만).
function gitignoreWarning(target: string): string | null {
  const dir = target.replace(/\/[^/]*$/, "") || "/";
  const inside = sh("git", ["-C", dir, "rev-parse", "--is-inside-work-tree"]);
  if (!inside.ok || inside.out.trim() !== "true") return null;
  const ignored = sh("git", ["-C", dir, "check-ignore", "-q", "--", target]);
  // rc 0 = 무시됨(정상) · rc 1 = 무시되지 않음(경고) · 그 외(에러) = 판정 불가라 침묵.
  if (ignored.status !== 1) return null;
  return `경고: 대상이 .gitignore 밖(${target}) — 자격 파일이므로 커밋 금지`;
}

// host 치환 — '첫 @'·'첫 /'을 잡는 정규식이 아니라 WHATWG URL host setter. userinfo(비밀번호의 @·/·%xx)를
// 보존하고 host+port만 바꾼다(bun 실측: `redis://ro:p@h@cache:6379`를 정규식은 `p`로 절단했고, setter는
// `p%40h`로 보존한다 — cache 생산자는 비밀번호를 URL 인코딩하지 않아 base64url 불변식에만 기대던 자리).
// 파싱 실패(conn 값이 URL이 아님)와 setter 미반영(술어가 놓친 불량 host를 setter가 조용히 무시하는 경우)은
// 둘 다 null — 콜사이트가 failure로 접는다. 값은 오류 문구 어디에도 싣지 않는다.
function rehost(conn: string, hostPort: string): string | null {
  let u: URL;
  try { u = new URL(conn); } catch { return null; }
  u.host = hostPort;
  if (u.host.toLowerCase() !== hostPort.toLowerCase()) return null;
  return u.toString();
}

function targetPath(envFile: string, envDir: string | undefined): string {
  return isAbsolute(envFile) ? envFile : join(envDir ?? process.cwd(), envFile);
}

function kubectlData(ns: string, secret: string, key: string): { ok: boolean; value: string; err: string } {
  const r = sh("kubectl", ["-n", ns, "get", "secret", secret, "-o", `jsonpath={.data.${key}}`]);
  // 키 부재 = 빈 출력·rc 0(jsonpath가 접는다) — rc만 보면 `KEY=`(빈 값) 행이 success/wrote:true로
  // 기록된다. `--allow-missing-template-keys=false`는 **쓰지 않는다**: 키 부재 시 kubectl stderr가
  // Secret 오브젝트 전체를 base64 data째 덤프해(라이브 실측) 시크릿 로그 유출 표면이 된다.
  if (r.ok && r.out === "") return { ok: false, value: "", err: `${ns}/${secret}의 키 ${key}가 비어 있거나 없다(jsonpath는 키 부재를 빈 출력·rc 0으로 접는다)` };
  return r.ok
    ? { ok: true, value: Buffer.from(r.out, "base64").toString("utf8"), err: "" }
    : { ok: false, value: "", err: r.err.split("\n")[0] || "kubectl 실패" };
}

// skip 결과 한 벌 — 두 동사가 같은 사유 문구를 낸다(UrlOutcome 타입 주석이 의미론 소유).
function skipNoCluster(base: UrlResult): UrlOutcome {
  return { variant: "skip", omitted: [], result: { ...base, wrote: false, note: "KUBECONFIG 미설정 — 클러스터 조회 없이 종료(계획은 --dry-run, 라이브는 KUBECONFIG 설정 후 재실행)" } };
}

export function runDbUrl(input: DbUrlInput): UrlOutcome {
  const mode = dbMode(input);
  const envFile = input.envLocal ?? mode.envFile;
  const base: UrlResult = { name: input.name, mode: mode.label, secretRef: `${mode.ns}/${mode.secret}`, envKey: mode.envKey, envFile, dryRun: input.dryRun === true };
  const failure = (error: string): UrlOutcome => ({ variant: "failure", omitted: [], result: { ...base, wrote: false, error } });
  const tsHost = input.host ?? process.env.TS_DB_HOST ?? "";
  if (input.dryRun === true) {
    // 계획은 클러스터 무의존이라 host가 없어도 success다 — 다만 **미해석 사실을 note가 말한다**.
    // 종전에는 dry-run이 host 해석 앞에서 성공해 "계획은 통과, 라이브는 --host 필요"가 됐다.
    const unresolved = tsHost === "" ? " ⚠️ host 미해석(host 입력 없음 — 라이브 실행 전 --host / MCP host / env TS_DB_HOST 중 하나 필요)" : "";
    return { variant: "success", omitted: [], result: { ...base, wrote: false, note: `평문 URL은 stdout에 출력하지 않음 — 라이브 실행 시 host를 tailscale로 치환해 대상 파일에만 기록${unresolved}` } };
  }
  // 문구는 transport 중립이어야 한다 — 이 error는 description이 아니라 Envelope의 result.error라
  // MCP 에이전트에게 그대로 간다(MCP 인자는 `host`이지 `--host`가 아니다).
  if (tsHost === "") return failure("host 입력(CLI --host / MCP host / env TS_DB_HOST) 필요 — pg-rw-tailscale LB host(런북 db-cache-access.md)");
  // host 미지정(입력 결함)은 skip(도메인 부재)보다 앞선다 — 도메인이 생겨도 host 없이는 라이브
  // 실행이 성립하지 않으니, 먼저 고칠 수 있는 것을 먼저 보고한다(cache url은 host 기본값이 있어
  // 이 축 자체가 없다 — 두 동사의 순서 비대칭은 그 차이다). env 폴백(TS_DB_HOST)도 같은 술어를 지난다
  // (--host는 입력 술어에서 이미 거부됐다 — 여기서 걸리는 것은 env 값이다).
  { const he = hostError(tsHost); if (he !== null) return failure(`TS_DB_HOST ${he}`); }
  if ((process.env.KUBECONFIG ?? "") === "") return skipNoCluster(base);
  let url: string;
  if (input.admin === true) {
    const user = kubectlData(mode.ns, mode.secret, "username");
    const pw = kubectlData(mode.ns, mode.secret, "password");
    if (!user.ok || !pw.ok) return failure(user.err || pw.err);
    url = `postgres://${encodeURIComponent(user.value)}:${encodeURIComponent(pw.value)}@${tsHost}:5432/${input.name}`;
  } else {
    const src = kubectlData(mode.ns, mode.secret, mode.srcKey);
    if (!src.ok) return failure(src.err);
    const swapped = rehost(src.value, `${tsHost}:5432`);
    if (swapped === null) return failure(`${mode.ns}/${mode.secret}의 키 ${mode.srcKey} 값이 URL로 파싱되지 않거나 host 치환이 반영되지 않았다(값은 출력하지 않음)`);
    url = swapped;
  }
  const target = targetPath(envFile, input.envDir);
  try { upsertEnv(target, mode.envKey, url); }
  catch (e) { return failure(e instanceof Error ? e.message : String(e)); }
  const warn = gitignoreWarning(target);
  return { variant: "success", omitted: [], result: { ...base, wrote: true, ...(warn === null ? {} : { note: warn }) } };
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
  // env 폴백(CACHE_LOCAL_HOST)도 host 술어를 지난다(--host는 입력 술어에서 이미 거부됐다).
  { const he = hostError(host); if (he !== null) return failure(`CACHE_LOCAL_HOST ${he}`); }
  if ((process.env.KUBECONFIG ?? "") === "") return skipNoCluster(base);
  const src = kubectlData(mode.ns, mode.secret, mode.srcKey);
  if (!src.ok) return failure(src.err);
  const url = rehost(src.value, `${host}:6379`);
  if (url === null) return failure(`${mode.ns}/${mode.secret}의 키 ${mode.srcKey} 값이 URL로 파싱되지 않거나 host 치환이 반영되지 않았다(값은 출력하지 않음)`);
  const target = targetPath(envFile, input.envDir);
  try { upsertEnv(target, mode.envKey, url); }
  catch (e) { return failure(e instanceof Error ? e.message : String(e)); }
  const warn = gitignoreWarning(target);
  return { variant: "success", omitted: [], result: { ...base, wrote: true, ...(warn === null ? {} : { note: warn }) } };
}
