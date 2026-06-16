// teardown-resource — DB/캐시 리소스 철거. 두 상태 머신을 분리한다:
//
// retain(기본): 리소스를 **보존**하되 참조 0이면 tombstone(state: retained)으로 표시 —
//   owner role/password/CR/conn 전부 유지(소유 role 없는 보존 DB는 접근 불가 고아가 되므로
//   retain은 아무것도 제거하지 않는다). 재생성 시 이 인벤토리로 결정적 복원.
//
// purge(--delete-data): 되돌릴 수 없으므로(git revert로 데이터 복구 불가 — 백업 복원만이
//   복구 경로) 게이트 + 재개 가능한 단계로 분해한다. 각 단계는 **별도 커밋/revision**으로
//   적용해야 한다(ensure:absent와 role 제거를 한 revision에 섞으면 CNPG reconcile 순서
//   비보장으로 cannotReconcile — 라이브 검증 함정):
//   --step tombstone : 신규 참조 차단 표시 (create-app 가드가 읽음)
//   --step drop      : Database CR spec.ensure: absent (논리 DB만 DROP — **PVC 비접촉**,
//                      공유 클러스터라 DB별 PVC가 없다; PVC를 지우면 클러스터 전체가 날아간다)
//   --step verify    : (라이브) Database CR status + 실제 DB 부재 확인 — 워크플로/owner가 kubectl로
//   --step cleanup   : CR 파일·conn sealed 제거 + tombstone state=purged (role 제거는
//                      cluster.yaml managed.roles에서 — 별도 커밋, 워크플로 단계)
//   모든 step은 멱등(중단→재실행 안전). --backup-verified <id> 없이는 drop/cleanup 거부
//   (최근 검증된 백업/복구 지점 강제 — postgres: CNPG barman, valkey: RDB 스냅샷 ID).
//
// 참조 집계는 **오직 apps/*/deploy/prod/.bindings.json**(homelab 권위 레지스트리)로만 한다 —
// envFrom 파싱이나 외부 앱 레포 config는 stale/접근불가일 수 있어 신뢰하지 않는다.
import { readFileSync, writeFileSync, existsSync, rmSync, readdirSync } from "node:fs";
import { parseDocument } from "yaml";

const arg = (k, d) => { const i = process.argv.indexOf(k); return i > -1 ? process.argv[i + 1] : d; };
const has = (k) => process.argv.includes(k);
const DRY = has("--dry-run");
const db = arg("--db");
const cache = arg("--cache");
const ROOT = arg("--repo-root", ".");
const deleteData = has("--delete-data");
const backupId = arg("--backup-verified");
const step = arg("--step", deleteData ? undefined : "tombstone");

const fail = (msg) => { console.error(`teardown-resource: ${msg}`); process.exit(1); };
if ((db ? 1 : 0) + (cache ? 1 : 0) !== 1) fail("--db <name> 또는 --cache <name> 중 정확히 하나");
const name = db ?? cache;
if (!/^[a-z][a-z0-9-]*$/.test(name)) fail(`이름 형식 불량: ${name}`);
const kind = db ? "db" : "cache";
const key = `${kind}:${name}`;

// ── 참조 수 집계 (권위: .bindings.json만) ──────────────────────────────────────
const appsRoot = `${ROOT}/apps`;
const referrers = [];
for (const a of existsSync(appsRoot) ? readdirSync(appsRoot) : []) {
  const b = `${appsRoot}/${a}/deploy/prod/.bindings.json`;
  if (!existsSync(b)) continue;
  try {
    const bindings = JSON.parse(readFileSync(b, "utf8"));
    const refs = kind === "db" ? bindings.db ?? [] : bindings.redis ?? [];
    if (refs.includes(name)) referrers.push(a);
  } catch { referrers.push(`${a}(bindings 파싱 불가 — 보수적으로 참조 취급)`); }
}
if (referrers.length > 0) fail(`참조 중인 앱이 있어 거부: ${referrers.join(", ")} — teardown-app 먼저`);

// ── tombstone 인벤토리 ────────────────────────────────────────────────────────
const tombPath = `${ROOT}/platform/data-conn/prod/.tombstones.json`;
const tombs = existsSync(tombPath) ? JSON.parse(readFileSync(tombPath, "utf8")) : {};
const writeTombs = () => writeFileSync(tombPath, JSON.stringify(tombs, null, 2) + "\n");

// 대상 산출물 경로
const dbDir = `${ROOT}/platform/cnpg/prod/databases`;
const crPath = `${dbDir}/${name}.yaml`;
const cacheDir = `${ROOT}/platform/cache/prod/${name}`;
const connFiles = [
  `${ROOT}/platform/data-conn/prod/${kind}-${name}-conn.sealed.yaml`,
  `${ROOT}/platform/data-conn/prod/${kind}-${name}-ro-conn.sealed.yaml`,
];
const dataConnKust = `${ROOT}/platform/data-conn/prod/kustomization.yaml`;
const dbKust = `${dbDir}/kustomization.yaml`;
const cacheKust = `${ROOT}/platform/cache/prod/kustomization.yaml`;

// purge cleanup이 제거할 (파일/디렉토리, 등록된 kustomization, resources 엔트리) — provision이
// 등록한 그대로를 역으로 제거한다. **파일만 rm하고 kustomization 엔트리를 남기면 kustomize
// build가 "missing file"로 죽어 cnpg-data/data-conn-prod/cache-prod 렌더가 파손된다**(적대적 리뷰).
const purgeArtifacts = kind === "db"
  ? [
      { file: crPath, kust: dbKust, entry: `${name}.yaml` },
      { file: `${dbDir}/db-${name}-owner.sealed.yaml`, kust: dbKust, entry: `db-${name}-owner.sealed.yaml` },
      { file: `${dbDir}/db-${name}-ro.sealed.yaml`, kust: dbKust, entry: `db-${name}-ro.sealed.yaml` },
      { file: connFiles[0], kust: dataConnKust, entry: `db-${name}-conn.sealed.yaml` },
      { file: connFiles[1], kust: dataConnKust, entry: `db-${name}-ro-conn.sealed.yaml` },
    ]
  : [
      { file: cacheDir, dir: true, kust: cacheKust, entry: name },
      { file: connFiles[0], kust: dataConnKust, entry: `cache-${name}-conn.sealed.yaml` },
      { file: connFiles[1], kust: dataConnKust, entry: `cache-${name}-ro-conn.sealed.yaml` },
    ];

// kustomization resources에서 엔트리 제거(멱등) — provision의 addResource를 역으로. trailing
// slash 정규화로 인스턴스 디렉토리 등록(name vs name/)도 매칭.
function deregister(kustPath, entry) {
  if (!existsSync(kustPath)) return;
  const doc = parseDocument(readFileSync(kustPath, "utf8"));
  const seq = doc.get("resources");
  if (!seq?.items) return;
  const norm = (v) => String(v).replace(/\/$/, "");
  const idx = seq.items.findIndex((it) => norm(it.value ?? it) === norm(entry));
  if (idx < 0) return;
  doc.deleteIn(["resources", idx]);
  writeFileSync(kustPath, doc.toString());
}

const plan = { resource: key, mode: deleteData ? "purge" : "retain", step, referrers: 0, backupId: backupId ?? null };

if (!deleteData) {
  // retain: 보존 + tombstone(retained)만 — 어떤 파일도 제거하지 않는다
  if (!DRY) {
    tombs[key] = { state: "retained", at: new Date().toISOString() };
    writeTombs();
  }
  console.log(JSON.stringify({ ...plan, action: "tombstone(retained) — 산출물 전부 보존" }, null, 2));
  process.exit(0);
}

// ── purge 상태 머신 ──────────────────────────────────────────────────────────
if (!backupId) fail("--delete-data는 --backup-verified <검증된 복구 지점 ID> 필수 (백업 신선도 게이트)");

switch (step) {
  case "tombstone": {
    if (!DRY) { tombs[key] = { state: "purging", backupId, at: new Date().toISOString() }; writeTombs(); }
    console.log(JSON.stringify({ ...plan, action: "tombstone(purging) — 신규 참조 차단" }, null, 2));
    break;
  }
  case "drop": {
    if (kind === "db") {
      if (!existsSync(crPath)) { console.log(JSON.stringify({ ...plan, action: "CR 없음 — 멱등 no-op" }, null, 2)); break; }
      let cr = readFileSync(crPath, "utf8");
      if (/ensure: absent/.test(cr)) { console.log(JSON.stringify({ ...plan, action: "이미 absent — 멱등 no-op" }, null, 2)); break; }
      // 논리 DB만 DROP — PVC/클러스터 비접촉
      cr = /ensure: present/.test(cr) ? cr.replace(/ensure: present/, "ensure: absent")
        : cr.replace(/^spec:\s*$/m, "spec:\n  ensure: absent");
      if (!/ensure: absent/.test(cr)) fail(`${crPath}에 ensure를 설정하지 못함 — 수동 확인 필요`);
      if (!DRY) writeFileSync(crPath, cr);
      console.log(JSON.stringify({ ...plan, action: "Database CR ensure: absent (논리 DB DROP, PVC 비접촉)" }, null, 2));
    } else {
      // valkey: 인스턴스 PVC만 — drop 단계는 Deployment scale-down 의미가 없어 cleanup으로 위임
      console.log(JSON.stringify({ ...plan, action: "cache는 drop 단계 없음 — verify 후 cleanup" }, null, 2));
    }
    break;
  }
  case "verify": {
    // 라이브 검증은 워크플로/owner 몫 — 여기서는 체크리스트만 출력 (도구는 클러스터 비접촉)
    console.log(JSON.stringify({
      ...plan,
      action: "라이브 검증 체크리스트",
      checks: kind === "db"
        ? [`kubectl -n database get database ${name} -o jsonpath='{.status.applied}' == true`,
           `공유 클러스터의 다른 DB 생존 확인`, `실제 DB 부재 확인(psql \\l)`]
        : [`kubectl -n cache get deploy ${name} 부재 또는 scale 0`, `RDB 복구 지점(${backupId}) 무결성`],
    }, null, 2));
    break;
  }
  case "cleanup": {
    if (!DRY) {
      // 파일 제거 + 같은 항목을 kustomization에서 등록 해제(둘 다 멱등 — 재실행 안전)
      for (const a of purgeArtifacts) {
        if (existsSync(a.file)) rmSync(a.file, a.dir ? { recursive: true } : {});
        deregister(a.kust, a.entry);
      }
      tombs[key] = { state: "purged", backupId, at: new Date().toISOString() };
      writeTombs();
    }
    console.log(JSON.stringify({
      ...plan,
      action: "cleanup — CR/인스턴스/conn 제거 + kustomization 등록 해제 + tombstone(purged)",
      manual: kind === "db" ? "cluster.yaml managed.roles에서 owner/_ro role 제거는 별도 커밋(워크플로 단계)" : "원장 행 제거 확인",
    }, null, 2));
    break;
  }
  default:
    fail(`알 수 없는 --step: ${step} (tombstone|drop|verify|cleanup)`);
}
