// create-database 프로비저너 — 공유 pg 클러스터(CNPG) 안의 논리 DB를 선언적으로 산출한다.
// _create-database.yaml(homelab-initiated workflow_dispatch)이 호출 — 결과물은 PR.
//
// 산출물(4+3):
//   1. CNPG Database CR            → platform/cnpg/prod/databases/<name>.yaml (database NS)
//   2. managed.roles 2개(owner/ro) → platform/cnpg/prod/cluster.yaml patch (yaml 라운드트립)
//   3. 비밀번호 SealedSecret 2개   → platform/cnpg/prod/databases/db-<name>-{owner,ro}.sealed.yaml
//   4. conn SealedSecret 2개       → platform/data-conn/prod/db-<name>-{conn,ro-conn}.sealed.yaml (prod NS)
//   + databases/·data-conn kustomization 멱등 등록, 상위 cnpg kustomization에 databases/ 추가.
//
// 불변식:
//   - owner == name 고정(입력 안 받음) — owner 공유 시 한쪽 teardown/회전이 다른 DB를 깬다(role↔DB 1:1).
//   - storage/cpu/mem/version은 받지 않는다 — 공유 클러스터 레벨 속성(cluster.yaml 별도 작업 + 원장 게이트).
//   - 논리 DB는 메모리 원장 행을 추가하지 않는다 — 공유 CNPG pod 안의 논리 객체라 9216Mi 게이트를 왜곡한다.
//   - 비밀번호/raw URL은 stdout·로그 어디에도 출력하지 않는다. 평문 Secret은 메모리에서만
//     조립해 kubeseal stdin으로 직행한다(디스크 비기록).
import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { randomBytes } from "node:crypto";
import { join } from "node:path";
import { RESOURCE_NAME_RE, EXT_RE, resourceNameError } from "./lib/identity.ts";
import { sealManifest } from "./lib/seal.ts";
import { parseFlags } from "./lib/cli.ts";
import { Document, parseDocument } from "yaml";

function fail(msg: string): never { console.error(`::error::provision-db: ${msg}`); process.exit(1); }

// ---------- 1) 인자 파싱 — 허용 밖 인자는 전부 거부 (fail-closed) ----------
type Args = { cluster: string; root: string; extensions: string[]; dryRun: boolean; name?: string };
function parseArgs(argv: string[]): Args {
  // parseFlags: unknown + arg 삼킴(값 누락 자리서 다음 --플래그 삼킴) fail-closed. --owner는 known(value)으로 받되 아래서 전용 메시지로 거부.
  let f: Record<string, string | boolean>;
  try { f = parseFlags(argv, { value: ["--name", "--extensions", "--cluster", "--repo-root", "--owner"], bool: ["--dry-run"] }); }
  catch (e) { fail(e instanceof Error ? e.message : String(e)); }
  if (f["--owner"] !== undefined) fail("owner는 입력받지 않는다 — 항상 name으로 고정 (owner 공유 시 teardown이 다른 DB를 깬다)");
  return {
    name: typeof f["--name"] === "string" ? f["--name"] : undefined,
    extensions: typeof f["--extensions"] === "string" ? f["--extensions"].split(",").map((s) => s.trim()).filter(Boolean) : [],
    cluster: typeof f["--cluster"] === "string" ? f["--cluster"] : "pg",
    root: typeof f["--repo-root"] === "string" ? f["--repo-root"] : ".",
    dryRun: f["--dry-run"] === true,
  };
}

const args = parseArgs(process.argv.slice(2));
if (!args.name) {
  console.error("usage: provision-db --name <db> [--extensions a,b] [--cluster pg] [--repo-root <dir>] [--dry-run]");
  process.exit(2);
}

// ---------- 2) 입력 검증 ----------
const name = args.name;
// 형식 + DB 예약 이름 + '-ro' 접미사(F8)를 공유 정책으로 단일 검사(디스패처 validate-mutation과 동일)
const nameErr = resourceNameError("db", name);
if (nameErr) fail(nameErr);
// cluster는 format만 — 기본값 'pg'가 DB 예약이라 resourceNameError("db",…)를 쓰면 자기 자신을 거부한다
if (!RESOURCE_NAME_RE.test(args.cluster)) fail(`cluster 형식 불량: '${args.cluster}'`);
if (new Set(args.extensions).size !== args.extensions.length) fail("extensions에 중복 항목");
for (const e of args.extensions) if (!EXT_RE.test(e)) fail(`extension 이름 불량: '${e}'`);

const owner = name; // owner == name 불변식 — role↔DB 1:1
const roRole = `${name}_ro`; // 읽기전용 롤 (모드2 디버깅용)
const ENV = name.replaceAll("-", "_").toUpperCase(); // kebab → UPPER_SNAKE (env 키 규약)

// ---------- 3) 경로 ----------
const ROOT = args.root;
const cnpgDir = join(ROOT, "platform/cnpg/prod");
const dbDir = join(cnpgDir, "databases");
const connDir = join(ROOT, "platform/data-conn/prod");
const certPath = join(ROOT, "tools/sealed-secrets-cert.pem");
const paths = {
  cr: join(dbDir, `${name}.yaml`),
  ownerSealed: join(dbDir, `db-${name}-owner.sealed.yaml`),
  roSealed: join(dbDir, `db-${name}-ro.sealed.yaml`),
  dbKust: join(dbDir, "kustomization.yaml"),
  parentKust: join(cnpgDir, "kustomization.yaml"),
  cluster: join(cnpgDir, "cluster.yaml"),
  connSealed: join(connDir, `db-${name}-conn.sealed.yaml`),
  roConnSealed: join(connDir, `db-${name}-ro-conn.sealed.yaml`),
  connKust: join(connDir, "kustomization.yaml"),
};

// ---------- 4) 중복/전제 검사 (읽기 전용 — dry-run도 동일하게 거른다) ----------
if (!existsSync(paths.cluster)) fail(`${paths.cluster} 없음 — repo-root가 homelab 레포 루트인지 확인`);
if (existsSync(paths.cr)) fail(`DB '${name}' 이미 존재 (${paths.cr}) — name은 전역 유일`);
if (existsSync(paths.connSealed)) fail(`conn 핸들 이미 존재 (${paths.connSealed}) — name은 전역 유일`);

const clusterDoc = parseDocument(readFileSync(paths.cluster, "utf8"));
const existingRoles: any = clusterDoc.getIn(["spec", "managed", "roles"]);
if (existingRoles?.items) {
  for (const item of existingRoles.items) {
    const n = item.get?.("name");
    if (n === owner || n === roRole) fail(`managed 롤 '${n}' 이미 존재 — 롤 이름은 전역 유일 (role↔DB 1:1)`);
  }
}

// ---------- 5) 계획 (비밀값/raw URL 절대 비포함 — PR 본문에 그대로 실린다) ----------
const plan = {
  ok: true,
  name,
  cluster: args.cluster,
  owner,
  roles: [owner, roRole],
  extensions: args.extensions,
  envKeys: [`${ENV}_DATABASE_URL`, `${ENV}_MIGRATE_DATABASE_URL`, `${ENV}_RO_DATABASE_URL`],
  handles: { conn: `db-${name}-conn`, roConn: `db-${name}-ro-conn` },
  files: [paths.cr, paths.ownerSealed, paths.roSealed, paths.connSealed, paths.roConnSealed,
    paths.dbKust, paths.parentKust, paths.cluster, paths.connKust],
  dryRun: args.dryRun,
  checklist: [
    `읽기전용 롤 GRANT SQL 후처리: CNPG managed role은 롤 생성만 하고 GRANT는 관리하지 않는다 — Database CR Ready 후 ${name} DB에서 적용 필요: GRANT CONNECT ON DATABASE "${name}" TO "${roRole}"; GRANT USAGE ON SCHEMA public TO "${roRole}"; GRANT SELECT ON ALL TABLES IN SCHEMA public TO "${roRole}"; ALTER DEFAULT PRIVILEGES FOR ROLE "${owner}" IN SCHEMA public GRANT SELECT ON TABLES TO "${roRole}";`,
    "envFrom 시크릿 변경(회전 포함)은 파드 재시작이 있어야 반영된다",
    "메모리 원장: 논리 DB는 행 추가 금지 — 공유 CNPG limit를 키울 때만 기존 CNPG 행을 갱신",
  ],
};

if (args.dryRun) {
  console.log(JSON.stringify(plan, null, 2));
  process.exit(0);
}

// ---------- 6) 봉인 준비 — cert 없이는 어떤 파일도 쓰지 않는다 (부분 산출 방지) ----------
if (!existsSync(certPath)) {
  fail(`tools/sealed-secrets-cert.pem 없음 — sealed-secrets 컨트롤러 가동 후 'kubeseal --fetch-cert'로 받아 커밋해야 봉인 가능`);
}

// 비밀번호: crypto.randomBytes — base64url이라 URL userinfo에 그대로 안전, 어떤 출력에도 비노출
const pwOwner = randomBytes(24).toString("base64url");
const pwRo = randomBytes(24).toString("base64url");

// 평문 Secret manifest는 메모리에서만 조립해 kubeseal stdin으로 직행 (봉인 SSOT = lib/seal.ts)
function seal(manifest: object, outPath: string) {
  try { return { outPath, content: sealManifest(manifest, certPath) }; }
  catch (e) { fail(e instanceof Error ? e.message : String(e)); } // strict catch(F11)·기존 exit 코드 보존
}

// 런타임은 PgBouncer(pg-pooler-rw) 경유 — 다중 앱 풀이 max_connections=50을 고갈시키지 않게.
// 마이그레이션은 session 시맨틱이 필요해 직결(pg-rw). ro도 직결 — 단일 인스턴스라 pg-ro
// Service는 endpoint가 없고(replica 전용), 디버깅 세션 역시 session 시맨틱이 필요하다.
const POOLER_HOST = "pg-pooler-rw.database.svc.cluster.local:5432";
const DIRECT_HOST = "pg-rw.database.svc.cluster.local:5432";
const url = (user: string, pw: string, host: string) => `postgres://${encodeURIComponent(user)}:${encodeURIComponent(pw)}@${host}/${name}`;

// 봉인을 파일 쓰기보다 전부 먼저 수행 — kubeseal 실패 시 부분 산출이 남지 않는다
const sealed = [
  seal({ // CNPG managed role passwordSecret 계약: kubernetes.io/basic-auth (username/password)
    apiVersion: "v1", kind: "Secret",
    metadata: { name: `db-${name}-owner`, namespace: "database" },
    type: "kubernetes.io/basic-auth",
    stringData: { username: owner, password: pwOwner },
  }, paths.ownerSealed),
  seal({
    apiVersion: "v1", kind: "Secret",
    metadata: { name: `db-${name}-ro`, namespace: "database" },
    type: "kubernetes.io/basic-auth",
    stringData: { username: roRole, password: pwRo },
  }, paths.roSealed),
  seal({ // 앱 소비용 conn 핸들 (prod NS — envFrom은 네임스페이스-로컬)
    apiVersion: "v1", kind: "Secret",
    metadata: { name: `db-${name}-conn`, namespace: "prod" },
    type: "Opaque",
    stringData: {
      [`${ENV}_DATABASE_URL`]: url(owner, pwOwner, POOLER_HOST),
      [`${ENV}_MIGRATE_DATABASE_URL`]: url(owner, pwOwner, DIRECT_HOST),
    },
  }, paths.connSealed),
  seal({
    apiVersion: "v1", kind: "Secret",
    metadata: { name: `db-${name}-ro-conn`, namespace: "prod" },
    type: "Opaque",
    stringData: { [`${ENV}_RO_DATABASE_URL`]: url(roRole, pwRo, DIRECT_HOST) },
  }, paths.roConnSealed),
];

// ---------- 7) CNPG Database CR ----------
const crDoc = new Document({
  apiVersion: "postgresql.cnpg.io/v1",
  kind: "Database",
  metadata: { name, namespace: "database" },
  spec: {
    cluster: { name: args.cluster },
    name,
    owner,
    ensure: "present",
    databaseReclaimPolicy: "retain",
    ...(args.extensions.length
      ? { extensions: args.extensions.map((e) => ({ name: e, ensure: "present" })) }
      : {}),
  },
});
crDoc.commentBefore = ` ${name} 논리 DB — create-database(provision-db.ts) 산출물.
 공유 pg 클러스터 안의 논리 객체라 메모리 원장 행을 추가하지 않는다(9216Mi 게이트 왜곡 방지).`;
(crDoc.getIn(["spec", "owner"], true) as any).comment = " owner == name 불변식 — role↔DB 1:1 (teardown 격리)";
(crDoc.getIn(["spec", "ensure"], true) as any).comment = " teardown은 absent 전환으로 (CR 삭제가 아니라)";
(crDoc.getIn(["spec", "databaseReclaimPolicy"], true) as any).comment = " CR이 사라져도 DB 보존 — 삭제는 teardown에서 명시적으로";
if (args.extensions.length) {
  // ensure: present는 서버 주입 기본값 — SSA atomic 리스트라 미기재 시 영구 OutOfSync
  (crDoc.getIn(["spec", "extensions", 0, "ensure"], true) as any).comment =
    " 서버 주입 기본값 명시 (SSA atomic 리스트 — cluster.yaml plugins.enabled와 동일 클래스)";
}

// ---------- 8) cluster.yaml managed.roles — yaml 라운드트립(주석/스타일 보존) ----------
if (!clusterDoc.hasIn(["spec", "managed", "roles"])) {
  clusterDoc.setIn(["spec", "managed", "roles"], clusterDoc.createNode([]));
}
const rolesSeq: any = clusterDoc.getIn(["spec", "managed", "roles"]);
rolesSeq.flow = false;
// 서버 주입 기본값(ensure/inherit/connectionLimit)을 명시 — SSA atomic 리스트 함정 회피
const mkRole = (roleName: string, secretName: string, comment: string) => {
  const node = clusterDoc.createNode({
    name: roleName,
    ensure: "present",
    login: true,
    inherit: true,
    connectionLimit: -1,
    passwordSecret: { name: secretName },
  });
  node.commentBefore = comment;
  return node;
};
rolesSeq.add(mkRole(owner, `db-${name}-owner`,
  ` ${name} owner — create-database 산출물. ensure/inherit/connectionLimit는 서버 주입 기본값 명시(SSA atomic 리스트)`));
rolesSeq.add(mkRole(roRole, `db-${name}-ro`,
  ` ${name} 읽기전용(모드2 디버깅) — GRANT는 managed role 범위 밖, PR checklist의 SQL 후처리 필요`));

// ---------- 9) kustomization 멱등 등록 ----------
// 시퀀스에 항목이 없을 때만 추가 — 기존 항목/주석은 그대로 보존된다.
// ★lib/kustomization.ts(string-기반)로 이주하지 않는다 — 이 헬퍼는 doc-배치(여러 add 후 1회 write)·
//   엔트리 comment(아래 databases/ 등록)·toString({lineWidth:0})·빈 배열 flow→block 동작이 달라
//   이주 시 직렬화/주석이 바뀐다(동작보존, plan Step5의 "차이 있으면 보존").
function addResource(doc: any, entry: string, comment?: string) {
  if (!doc.has("resources")) doc.set("resources", doc.createNode([]));
  const seq = doc.get("resources");
  const norm = (v: any) => String(v).replace(/\/$/, "");
  if (seq.items.some((it: any) => norm(it.value ?? it) === norm(entry))) return false;
  const node = doc.createNode(entry);
  if (comment) node.comment = comment;
  seq.add(node);
  seq.flow = false; // 빈 [](플로우)에서 출발해도 블록 스타일로
  return true;
}

// databases/ 하위 kustomization — KSOPS 없이 `kustomize build`로 단독 검증 가능하게 유지
const dbKustDoc = existsSync(paths.dbKust)
  ? parseDocument(readFileSync(paths.dbKust, "utf8"))
  : parseDocument(`# create-database가 관리하는 논리 DB 디렉토리 — 상위 platform/cnpg/prod kustomization이
# resources로 포함한다. KSOPS 풀렌더 없이 \`kustomize build platform/cnpg/prod/databases\`로
# 단독 검증 가능하도록 별도 kustomization을 유지한다.
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: database
resources: []
`);
addResource(dbKustDoc, `${name}.yaml`);
addResource(dbKustDoc, `db-${name}-owner.sealed.yaml`);
addResource(dbKustDoc, `db-${name}-ro.sealed.yaml`);

// 상위 cnpg kustomization에 databases/ 추가 (이미 있으면 멱등)
const parentDoc = parseDocument(readFileSync(paths.parentKust, "utf8"));
addResource(parentDoc, "databases/", " 논리 DB + owner/ro 시크릿 (create-database 산출물)");

// data-conn 컴포넌트 (prod NS) — 없으면 신설 (appset이 data-conn-prod로 자동 발견)
const connKustDoc = existsSync(paths.connKust)
  ? parseDocument(readFileSync(paths.connKust, "utf8"))
  : parseDocument(`# 앱 소비용 conn SealedSecret 컴포넌트 (prod NS) — provision-db.ts가 신설/등록.
# platform-components ApplicationSet이 data-conn-prod Application으로 자동 발견한다.
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: prod
resources: []
`);
addResource(connKustDoc, `db-${name}-conn.sealed.yaml`);
addResource(connKustDoc, `db-${name}-ro-conn.sealed.yaml`);

// ---------- 10) 쓰기 (모든 조립이 성공한 뒤에만) ----------
mkdirSync(dbDir, { recursive: true });
mkdirSync(connDir, { recursive: true });
const OPTS = { lineWidth: 0 }; // 긴 기존 주석/스칼라 재줄바꿈 금지 (diff 노이즈 방지)
writeFileSync(paths.cr, crDoc.toString(OPTS));
for (const { outPath, content } of sealed) writeFileSync(outPath, content);
writeFileSync(paths.dbKust, dbKustDoc.toString(OPTS));
writeFileSync(paths.parentKust, parentDoc.toString(OPTS));
writeFileSync(paths.cluster, clusterDoc.toString(OPTS));
writeFileSync(paths.connKust, connKustDoc.toString(OPTS));

console.log(JSON.stringify(plan, null, 2));
