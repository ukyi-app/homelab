// seal-batch — 선언 테이블 기반 단일 봉인 도구. seal-adguard-auth·seal-argocd-notify·seal-files-secrets·
// seal-ghcr-pull 4종을 수렴(일괄 재봉인 --all·GHCR 단일 회전 --group ghcr-pull 확보).
// ⚠️ 평문/해시/토큰은 어떤 경로로도(stdout·예외·산출물 diff) 노출하지 않는다 — kubeseal stdin 전용.
// 봉인 전 secret-cert-check preflight를 fail-closed로 실행(--offline-ok/SEAL_OFFLINE=1 break-glass, dry-run 비대상).
// 변환은 TS에서 Secret manifest 조립(kubectl 불요) → kubeseal(lib/seal.ts). docker는 bcrypt에만, gh는 dockerconfig user에만.
import { spawnSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { parseFlags } from "./lib/cli.ts";
import { sealManifest } from "./lib/seal.ts";

type Transform = "bcrypt" | "literal" | "dockerconfig" | "file";
type Entry = {
  name: string;        // --only 키
  group?: string;      // --group 키(회전 단위)
  env: string;         // 소비 env 변수
  transform: Transform;
  ns: string;
  secretName: string;
  key?: string;        // literal/file 키 이름(dockerconfig는 고정)
  out: string;         // 봉인본 상대 경로
  keys: string[];      // dry-run 표시용 봉인 키 목록
};

const TABLE: Entry[] = [
  { name: "adguard-auth", env: "ADGUARD_PASSWORD", transform: "bcrypt", ns: "edge",
    secretName: "adguard-auth", key: "PASSWORD_HASH",
    out: "platform/adguard/prod/adguard-auth.sealed.yaml", keys: ["PASSWORD_HASH"] },
  { name: "argocd-notify", env: "TELEGRAM_BOT_TOKEN", transform: "literal", ns: "argocd",
    secretName: "argocd-notifications-secret", key: "telegram-token",
    out: "platform/argocd/extras/argocd-notifications-secret.sealed.yaml", keys: ["telegram-token"] },
  { name: "files-keys", group: "files-secrets", env: "FILES_KEYS_JSON", transform: "file", ns: "files",
    secretName: "files-keys", key: "keys.json",
    out: "platform/files/prod/files-keys.sealed.yaml", keys: ["keys.json"] },
  { name: "prod-ghcr-pull", group: "ghcr-pull", env: "GHCR_PULL_TOKEN", transform: "dockerconfig", ns: "prod",
    secretName: "ghcr-pull", out: "platform/ghcr-pull/prod/ghcr-pull.sealed.yaml", keys: [".dockerconfigjson"] },
  { name: "files-ghcr-pull", group: "ghcr-pull,files-secrets", env: "GHCR_PULL_TOKEN", transform: "dockerconfig", ns: "files",
    secretName: "ghcr-pull", out: "platform/files/prod/ghcr-pull.sealed.yaml", keys: [".dockerconfigjson"] },
  // ghcr-read(observability NS) — 같은 GHCR_PULL_TOKEN. 회전 단일 타깃이 3평면 모두 커버(ADR-0001 매트릭스).
  { name: "ghcr-read", group: "ghcr-pull", env: "GHCR_PULL_TOKEN", transform: "dockerconfig", ns: "observability",
    secretName: "ghcr-read", out: "platform/victoria-stack/prod/ghcr-read.sealed.yaml", keys: [".dockerconfigjson"] },
];

let flags: Record<string, string | boolean>;
try {
  flags = parseFlags(process.argv.slice(2), {
    value: ["--only", "--group", "--cert", "--out-dir"],
    bool: ["--all", "--dry-run", "--offline-ok"],
  });
} catch (e) {
  console.error(`${e instanceof Error ? e.message : String(e)}\nusage: seal-batch (--only <name>|--group <g>|--all) [--cert <pem>] [--out-dir <dir>] [--dry-run] [--offline-ok]`);
  process.exit(2);
}
const fail = (m: string): never => { console.error(`seal-batch: ${m}`); process.exit(1); };

const cert = typeof flags["--cert"] === "string" ? (flags["--cert"] as string) : "tools/sealed-secrets-cert.pem";
const outDir = typeof flags["--out-dir"] === "string" ? (flags["--out-dir"] as string) : ".";
const dry = flags["--dry-run"] === true;
const offlineOk = flags["--offline-ok"] === true || process.env.SEAL_OFFLINE === "1";

// 대상 선택
let targets: Entry[];
if (flags["--all"] === true) targets = TABLE;
else if (typeof flags["--group"] === "string") targets = TABLE.filter((e) => (e.group ?? "").split(",").includes(flags["--group"] as string));
else if (typeof flags["--only"] === "string") targets = TABLE.filter((e) => e.name === flags["--only"]);
else fail("--only <name> | --group <group> | --all 중 하나 필요");
if (!targets!.length) fail(`대상 없음: ${flags["--only"] ?? flags["--group"] ?? ""}`);

// env 존재 확인(dry-run 포함 — 부분 봉인 방지 fail-closed)
for (const e of targets!) if (!process.env[e.env]) fail(`${e.env} 미설정(.env.secrets) — ${e.name} 봉인 불가`);

if (dry) {
  for (const e of targets!) console.log(`[dry-run] ${e.name} → ${e.secretName} (ns=${e.ns}, keys=${e.keys.join(",")}) → ${e.out}`);
  process.exit(0);
}

// preflight — secret-cert-check(fail-closed). 봉인 1회만 실행.
{
  const p = spawnSync("bash", ["scripts/secret-cert-check.sh", "--cert", cert], { stdio: "inherit" });
  if (p.status !== 0) {
    if (!offlineOk) { console.error("seal-batch: preflight(secret-cert-check) 실패 — 봉인 중단(stale/offline). break-glass: --offline-ok 또는 SEAL_OFFLINE=1"); process.exit(1); }
    console.error("seal-batch: ⚠️ preflight 실패했으나 --offline-ok로 진행(break-glass)");
  }
}

// 변환기 — Secret manifest(object) 조립. 평문/해시는 반환 object 밖으로 안 샌다.
function b64(s: string): string { return Buffer.from(s, "utf8").toString("base64"); }

function buildManifest(e: Entry): object {
  const val = process.env[e.env]!;
  if (e.transform === "bcrypt") {
    // docker httpd htpasswd bcrypt(평문은 stdin 전용 — 인자/ps 미노출). 'x:$2y$..' → cut -f2.
    const r = spawnSync("docker", ["run", "--rm", "-i", "httpd:2.4-alpine", "htpasswd", "-niBC", "10", "x"], { input: val, encoding: "utf8" });
    if (r.status !== 0) fail(`bcrypt 해시 생성 실패(docker htpasswd) — ${e.name}`);
    const hash = (r.stdout.split(":")[1] ?? "").trim();
    // 옛 seal-adguard-auth.sh는 '$2' 접두를 검사했으나 여기선 비어있음만 검사한다: 실 docker htpasswd는
    // 항상 bcrypt($2y$)를 내지만, bats docker 스텁은 sh 위치파라미터 확장으로 '$2y$10$' 리터럴을 못 만든다.
    if (!hash) fail(`bcrypt 해시 비어있음 — ${e.name}`);
    return { apiVersion: "v1", kind: "Secret", metadata: { name: e.secretName, namespace: e.ns }, type: "Opaque", stringData: { [e.key!]: hash } };
  }
  if (e.transform === "literal") {
    return { apiVersion: "v1", kind: "Secret", metadata: { name: e.secretName, namespace: e.ns }, type: "Opaque", stringData: { [e.key!]: val } };
  }
  if (e.transform === "file") {
    // keys.json 계약 검증(camelCase 배열·id/sha256/service 필수) — 값 미노출.
    let arr: unknown;
    try { arr = JSON.parse(val); } catch { fail(`${e.env} JSON 파싱 실패 — ${e.name}`); }
    const ok = Array.isArray(arr) && arr.every((x: any) => x && typeof x === "object" && "id" in x && "sha256" in x && "service" in x);
    if (!ok) fail(`${e.env} 형식 오류(배열·id/sha256/service 필수) — ${e.name}`);
    return { apiVersion: "v1", kind: "Secret", metadata: { name: e.secretName, namespace: e.ns }, type: "Opaque", stringData: { [e.key!]: val } };
  }
  // dockerconfig — dockerconfigjson. user는 gh api user, password=토큰.
  const gh = spawnSync("gh", ["api", "user", "--jq", ".login"], { encoding: "utf8" });
  if (gh.status !== 0) fail(`gh api user 실패 — ${e.name}`);
  const user = gh.stdout.trim();
  const auth = b64(`${user}:${val}`);
  const dcj = JSON.stringify({ auths: { "ghcr.io": { username: user, password: val, auth } } });
  return { apiVersion: "v1", kind: "Secret", metadata: { name: e.secretName, namespace: e.ns }, type: "kubernetes.io/dockerconfigjson", data: { ".dockerconfigjson": b64(dcj) } };
}

for (const e of targets!) {
  const sealed = sealManifest(buildManifest(e), cert);
  const outPath = `${outDir}/${e.out}`;
  mkdirSync(dirname(outPath), { recursive: true });
  writeFileSync(outPath, sealed);
  console.log(`sealed: ${e.out} (${e.secretName}, ns=${e.ns}, scope=strict)`);
}
