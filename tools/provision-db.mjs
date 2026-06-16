#!/usr/bin/env node
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
//   - 논리 DB는 메모리 원장 행을 추가하지 않는다 — 공유 CNPG pod 안의 논리 객체라 8704Mi 게이트를 왜곡한다.
//   - 비밀번호/raw URL은 stdout·로그 어디에도 출력하지 않는다. 평문 Secret은 메모리에서만
//     조립해 kubeseal stdin으로 직행한다(디스크 비기록).
import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { join } from "node:path";
import { Document, parseDocument } from "yaml";

const fail = (msg) => { console.error(`::error::provision-db: ${msg}`); process.exit(1); };

// ---------- 1) 인자 파싱 — 허용 밖 인자는 전부 거부 (fail-closed) ----------
function parseArgs(argv) {
  const args = { cluster: "pg", root: ".", extensions: [], dryRun: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--name") args.name = argv[++i];
    else if (a === "--extensions") args.extensions = (argv[++i] ?? "").split(",").map((s) => s.trim()).filter(Boolean);
    else if (a === "--cluster") args.cluster = argv[++i];
    else if (a === "--repo-root") args.root = argv[++i];
    else if (a === "--dry-run") args.dryRun = true;
    else if (a === "--owner") fail("owner는 입력받지 않는다 — 항상 name으로 고정 (owner 공유 시 teardown이 다른 DB를 깬다)");
    else fail(`알 수 없는 인자: ${a}`);
  }
  return args;
}

const args = parseArgs(process.argv.slice(2));
if (!args.name) {
  console.error("usage: provision-db --name <db> [--extensions a,b] [--cluster pg] [--repo-root <dir>] [--dry-run]");
  process.exit(2);
}

// ---------- 2) 입력 검증 ----------
const NAME_RE = /^[a-z]([a-z0-9-]*[a-z0-9])?$/; // validate-mutation.mjs와 동일 계열 (kebab-case)
const EXT_RE = /^[a-z][a-z0-9_-]*$/;
// 예약 이름: bootstrap initdb(app), 시스템 롤/DB — 충돌 시 클러스터가 깨진다
const RESERVED = new Set(["app", "postgres", "pg", "template0", "template1", "streaming_replica"]);

const name = args.name;
if (!NAME_RE.test(name) || name.length > 30) fail(`name 형식 불량(kebab-case, ≤30자): '${name}'`);
if (RESERVED.has(name)) fail(`예약 이름: '${name}' — bootstrap/시스템 객체와 충돌`);
// -ro 접미사 예약: db 'foo-ro'의 conn 파일(db-foo-ro-conn)이 db 'foo'의 읽기전용
// conn(db-foo-ro-conn)과 충돌해 한쪽을 조용히 덮어쓴다 → 접미사 자체를 금지.
if (/-ro$/.test(name)) fail(`'-ro' 접미사 예약: '${name}' — 읽기전용 conn 이름과 충돌`);
if (!NAME_RE.test(args.cluster)) fail(`cluster 형식 불량: '${args.cluster}'`);
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
const existingRoles = clusterDoc.getIn(["spec", "managed", "roles"]);
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

// 평문 Secret manifest는 메모리에서만 조립해 kubeseal stdin으로 직행 (seal-secret.mjs와 동일 패턴)
function seal(manifest, outPath) {
  const res = spawnSync("kubeseal", ["--cert", certPath, "--format", "yaml"], {
    input: JSON.stringify(manifest), // kubeseal은 JSON manifest도 받는다(YAML 슈퍼셋)
    encoding: "utf8",
  });
  if (res.error) fail(`kubeseal 실행 실패: ${res.error.message}`);
  if (res.status !== 0) fail(`kubeseal 종료 코드 ${res.status} — cert/컨트롤러 점검 (stderr는 값 미포함 시에만 확인)`);
  return { outPath, content: res.stdout };
}

// 런타임은 PgBouncer(pg-pooler-rw) 경유 — 다중 앱 풀이 max_connections=50을 고갈시키지 않게.
// 마이그레이션은 session 시맨틱이 필요해 직결(pg-rw). ro도 직결 — 단일 인스턴스라 pg-ro
// Service는 endpoint가 없고(replica 전용), 디버깅 세션 역시 session 시맨틱이 필요하다.
const POOLER_HOST = "pg-pooler-rw.database.svc.cluster.local:5432";
const DIRECT_HOST = "pg-rw.database.svc.cluster.local:5432";
const url = (user, pw, host) => `postgres://${encodeURIComponent(user)}:${encodeURIComponent(pw)}@${host}/${name}`;

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
crDoc.commentBefore = ` ${name} 논리 DB — create-database(provision-db.mjs) 산출물.
 공유 pg 클러스터 안의 논리 객체라 메모리 원장 행을 추가하지 않는다(8704Mi 게이트 왜곡 방지).`;
crDoc.getIn(["spec", "owner"], true).comment = " owner == name 불변식 — role↔DB 1:1 (teardown 격리)";
crDoc.getIn(["spec", "ensure"], true).comment = " teardown은 absent 전환으로 (CR 삭제가 아니라)";
crDoc.getIn(["spec", "databaseReclaimPolicy"], true).comment = " CR이 사라져도 DB 보존 — 삭제는 teardown에서 명시적으로";
if (args.extensions.length) {
  // ensure: present는 서버 주입 기본값 — SSA atomic 리스트라 미기재 시 영구 OutOfSync
  crDoc.getIn(["spec", "extensions", 0, "ensure"], true).comment =
    " 서버 주입 기본값 명시 (SSA atomic 리스트 — cluster.yaml plugins.enabled와 동일 클래스)";
}

// ---------- 8) cluster.yaml managed.roles — yaml 라운드트립(주석/스타일 보존) ----------
if (!clusterDoc.hasIn(["spec", "managed", "roles"])) {
  clusterDoc.setIn(["spec", "managed", "roles"], clusterDoc.createNode([]));
}
const rolesSeq = clusterDoc.getIn(["spec", "managed", "roles"]);
rolesSeq.flow = false;
// 서버 주입 기본값(ensure/inherit/connectionLimit)을 명시 — SSA atomic 리스트 함정 회피
const mkRole = (roleName, secretName, comment) => {
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
// 시퀀스에 항목이 없을 때만 추가 — 기존 항목/주석은 그대로 보존된다
function addResource(doc, entry, comment) {
  if (!doc.has("resources")) doc.set("resources", doc.createNode([]));
  const seq = doc.get("resources");
  const norm = (v) => String(v).replace(/\/$/, "");
  if (seq.items.some((it) => norm(it.value ?? it) === norm(entry))) return false;
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
  : parseDocument(`# 앱 소비용 conn SealedSecret 컴포넌트 (prod NS) — provision-db.mjs가 신설/등록.
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
