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
//   --step tombstone : purge 진행 표시(state=purging) — audit-orphans가 incomplete-purge로 감시
//                      (구 create-app tombstone 가드는 연결=SealedSecret 전환으로 제거됨; 강제 차단 아님)
//   --step drop      : Database CR spec.ensure: absent (논리 DB만 DROP — **PVC 비접촉**,
//                      공유 클러스터라 DB별 PVC가 없다; PVC를 지우면 클러스터 전체가 날아간다)
//                      **+ pgdump 헤지 DBS에서 이름 제거(같은 단계)** — 헤지 잡은 `set -euo pipefail`이라
//                      DROP된 DB 하나가 잡 전체를 죽여 뒤에 선 DB의 덤프까지 잃는다. test_pgdump_hedge도
//                      absent CR의 DBS **부재**를 요구한다(양방향 정합). cleanup은 같은 제거를 한 번 더
//                      시도하지만 이미 빠져 있으면 no-op이다(중단→재개 안전 벨트).
//   --step verify    : (라이브) Database CR status + 실제 DB 부재 확인 — 워크플로/owner가 kubectl로
//   --step cleanup   : CR 파일·conn sealed 제거 + tombstone state=purged (role 제거는
//                      cluster.yaml managed.roles에서 — 별도 커밋, 워크플로 단계).
//                      **drop 뒤에만 온다** — CR이 아직 `ensure: absent`가 아니면 fail-closed다
//                      (헤지 DBS 제거가 살아 있는 DB를 백업 목록에서 빼는 동작이 되므로).
//   모든 step은 멱등(중단→재실행 안전). --backup-verified <id> 없이는 drop/cleanup 거부
//   (최근 검증된 백업/복구 지점 강제 — postgres: CNPG barman, valkey: RDB 스냅샷 ID).
//
// 자동 refcount는 제거됐다(연결=SealedSecret이라 .bindings.json에 db/redis 참조가 없다) — 대신
// 모든 teardown(retain/purge)은 --refs-verified <id> attestation을 강제한다(owner가 런북 수동
// 확인: 사용 앱 grep + 실행 워크로드 kubectl + 백업 검증 후 증거 id 전달; F1 강화).
import { readFileSync, writeFileSync, existsSync, rmSync } from "node:fs";
import { resourceNameError } from "./lib/identity.ts";
import { TOMBSTONES_PATH, layoutFor, purgeArtifactsFor } from "./lib/resource-layout.ts";
import { replaceTotals, removeRow, parseLedgerRows } from "./lib/ledger-totals.ts";
import { removeResource } from "./lib/kustomization.ts";
import { hasDb, removeDb } from "./lib/hedge-dbs.ts";
import { parseFlags } from "./lib/cli.ts";

// parseFlags: unknown 옵션 + arg 삼킴 fail-closed(arg()/has()가 미지정 플래그를 조용히 무시하던 것 차단). 종료 코드 2 보존.
let __f: Record<string, string | boolean>;
try { __f = parseFlags(process.argv.slice(2), { value: ["--db", "--cache", "--repo-root", "--backup-verified", "--refs-verified", "--step"], bool: ["--delete-data", "--dry-run"] }); }
catch (e) { console.error(`${e instanceof Error ? e.message : String(e)}\n허용: --db --cache --repo-root --backup-verified --refs-verified --step --delete-data --dry-run`); process.exit(2); }
const arg = (k: string, d?: string) => (typeof __f[k] === "string" ? __f[k] as string : d);
const has = (k: string) => __f[k] === true;
const DRY = has("--dry-run");
const db = arg("--db");
const cache = arg("--cache");
const ROOT = arg("--repo-root", ".");
const deleteData = has("--delete-data");
const backupId = arg("--backup-verified");
const refsVerified = arg("--refs-verified");
const step = arg("--step", deleteData ? undefined : "tombstone");

const fail = (msg: string): never => { console.error(`teardown-resource: ${msg}`); process.exit(1); };
if ((db ? 1 : 0) + (cache ? 1 : 0) !== 1) fail("--db <name> 또는 --cache <name> 중 정확히 하나");
const name = (db ?? cache)!;
const kind: "db" | "cache" = db ? "db" : "cache";
// 이름 정책은 provision과 **같은 SSOT**다(identity.resourceNameError) — 형식만 보던 옛 판정은
// 예약·부트스트랩 이름(`app`·`postgres`…, `-ro` 접미)을 통과시켰고, 그 이름들은 CR 파일이 없어
// "CR 없음 — 멱등 no-op"을 출력하면서 **공유 표면**(pgdump 헤지 DBS)만 편집했다. `--db app` 한 번이
// restore_canary를 담은 부트스트랩 DB를 논리 백업 0으로 만든다. 철거가 만들 수 없는 이름을
// 받아들일 이유가 없으므로 fail-closed다(정책이 갈리면 그 자체가 우회 표면 — identity.ts 주석).
const nameErr = resourceNameError(kind, name);
if (nameErr) fail(nameErr);
// 산출물 명명·배치는 레이아웃 커널 소유 — provision과 같은 값을 쓴다
// (원장 행·엔트리 이름 추정 어긋남 F1 클래스의 구조적 소멸).
const layout = kind === "db" ? layoutFor("db", name) : layoutFor("cache", name);
const key = layout.tombstoneKey;

// ── refs-verified attestation 게이트 (F1 강화) ────────────────────────────────
// db: 필드 제거로 자동 refcount는 불가하다 — 대신 owner가 "사용 앱 수동 확인 완료"를 명시 attest해야
// 모든 teardown(retain/purge)이 진행한다. 증거 id는 런북 체크리스트 수행 기록(apps/*/deploy/prod grep +
// 실행 워크로드 kubectl + 백업 검증). 기계 검증은 아니지만 "그냥 실행"을 막는 강제 게이트.
if (!refsVerified || !refsVerified.trim())
  fail("--refs-verified <evidence-id> 필수 — 런북 수동 확인(사용 앱 0 + 백업) 후 증거 id를 전달하라");

// ── tombstone 인벤토리 ────────────────────────────────────────────────────────
const tombPath = `${ROOT}/${TOMBSTONES_PATH}`;
const tombs = existsSync(tombPath) ? JSON.parse(readFileSync(tombPath, "utf8")) : {};
const writeTombs = () => writeFileSync(tombPath, JSON.stringify(tombs, null, 2) + "\n");

// drop 단계가 편집하는 Database CR — db 전용(커널 정준형 + ROOT 결합).
const crPath = layout.kind === "db" ? `${ROOT}/${layout.paths.cr}` : "";

// pgdump 헤지 DBS — db 전용 **공유-잔존** 표면(파일은 남고 토큰 하나만 빠진다). 경로·토큰 모두
// 레이아웃 커널이 주고(`paths.hedge`·`hedgeEntry` — 지역 재유도 금지), 줄 문법은 lib/hedge-dbs.ts
// 소유. 파일 부재·포맷 드리프트는 fail-closed다: 조용한 skip은 "DB는 DROP됐는데 목록엔 남아
// 있다"를 남기고, 그건 다음 04:00 헤지 잡의 전멸(그리고 PR 게이트 red)로 착지한다.
const hedgePath = layout.kind === "db" ? `${ROOT}/${layout.paths.hedge}` : "";
const hedgeEntry = layout.kind === "db" ? layout.hedgeEntry : "";

// 헤지 갱신본을 **조립만** 한다 — write는 호출부가 낸다. 두 파일(CR·헤지)을 고치는 단계에서
// 조립·검증을 write보다 앞세워야 한쪽만 쓰인 반쪽 전이가 생기지 않는다.
// text === null = 쓸 것이 없다(부재). 부재 판정을 **편집과 같은 문법**(hasDb)으로 먼저 하는 이유:
// 커널의 산출 형식은 정준(공백 축약)이라, 텍스트 diff로 멱등을 재면 비정규 공백 위에서 "없는
// 이름 제거"가 공유 매니페스트를 건드리는 diff를 낳는다.
type HedgePlan = { text: string | null; note: string };
function planHedgeRemoval(): HedgePlan {
  if (!existsSync(hedgePath)) fail(`${hedgePath} 없음 — pgdump 헤지 DBS에서 '${hedgeEntry}'을 뺄 수 없다 (repo-root 확인)`);
  const before = readFileSync(hedgePath, "utf8");
  try {
    if (!hasDb(before, hedgeEntry)) return { text: null, note: "DBS 이미 부재 — 멱등 no-op(파일 비접촉)" };
    return { text: removeDb(before, hedgeEntry), note: `DBS에서 '${hedgeEntry}' 제거` };
  } catch (e) { return fail(e instanceof Error ? e.message : String(e)); }
}
const writeHedge = (h: HedgePlan) => { if (h.text !== null && !DRY) writeFileSync(hedgePath, h.text); };

// purge cleanup이 제거할 (파일/디렉토리, 등록된 kustomization, resources 엔트리) — 커널의
// purge 삼중이 provision 등록의 정확한 역이다. **파일만 rm하고 kustomization 엔트리를 남기면
// kustomize build가 "missing file"로 죽어 cnpg-data/data-conn-prod/cache-prod 렌더가 파손된다**(적대적 리뷰).
const purgeArtifacts = purgeArtifactsFor(kind, name)
  .map((a) => ({ ...a, file: `${ROOT}/${a.file}`, kust: `${ROOT}/${a.kust}` }));


const plan = { resource: key, mode: deleteData ? "purge" : "retain", step, refsVerified, backupId: backupId ?? null };

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
    console.log(JSON.stringify({ ...plan, action: "tombstone(purging) — purge 진행 표시(audit incomplete-purge 감시)" }, null, 2));
    break;
  }
  case "drop": {
    if (kind === "db") {
      // 헤지 갱신본을 CR 편집보다 **먼저** 조립한다 — 파일 부재·포맷 드리프트를 여기서 fail-closed로
      // 걸어야 "CR만 absent인데 헤지 목록엔 남았다"는 반쪽 전이가 생기지 않는다(아직 write는 없다).
      const hedge = planHedgeRemoval();
      if (!existsSync(crPath)) {
        // **대상이 실재하지 않으면 헤지도 쓰지 않는다.** CR 없는 이름으로 공유 목록을 편집하면
        // "CR 없음 — 멱등 no-op"이라는 보고와 파일 변경이 서로 모순된다. 잔존만 보고하고 손을 뗀다.
        const note = hedge.text === null ? "DBS 부재 — 비접촉"
          : `DBS에 '${hedgeEntry}' 잔존 — CR이 없어 헤지 비접촉(수동 확인)`;
        console.log(JSON.stringify({ ...plan, hedge: note, action: "CR 없음 — 멱등 no-op" }, null, 2));
        break;
      }
      const crBefore = readFileSync(crPath, "utf8");
      if (/ensure: absent/.test(crBefore)) {
        writeHedge(hedge); // CR은 이미 absent — 헤지 잔존만 마저 걷어낸다(재개 안전)
        console.log(JSON.stringify({ ...plan, hedge: hedge.note, action: "이미 absent — 멱등 no-op" }, null, 2));
        break;
      }
      // 논리 DB만 DROP — PVC/클러스터 비접촉. 두 갱신본을 **먼저 조립·검증**하고(ensure: absent 단언
      // 포함) 그 뒤에 두 write를 연달아 낸다 — CR 편집이 실패할 수 있는 자리를 write 앞에 모은다.
      const crNext = /ensure: present/.test(crBefore) ? crBefore.replace(/ensure: present/, "ensure: absent")
        : crBefore.replace(/^spec:\s*$/m, "spec:\n  ensure: absent");
      if (!/ensure: absent/.test(crNext)) fail(`${crPath}에 ensure를 설정하지 못함 — 수동 확인 필요`);
      if (!DRY) { writeHedge(hedge); writeFileSync(crPath, crNext); }
      console.log(JSON.stringify({ ...plan, hedge: hedge.note, action: "Database CR ensure: absent (논리 DB DROP, PVC 비접촉)" }, null, 2));
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
    // 헤지 제거는 '무조건 벨트'가 아니라 **선행 조건 검사**다. drop을 건너뛰고 바로 오면 CR은
    // 아직 present이고, 그때의 무조건 제거는 **살아 있는 DB**를 조용히 백업 목록에서 빼는 동작이다
    // (다음 04:00부터 그 DB의 논리 백업이 0인데 잡은 녹색으로 끝난다). CR이 없거나 이미 absent일
    // 때만 멱등 제거하고, 그 밖에는 fail-closed다. 판정·조립 전부 파괴 작업 **앞**에 둔다 —
    // 헤지를 못 고치는 상태라면 파일을 지우기 전에 abort하는 쪽이 옳다.
    let hedgeNote = "헤지는 논리 DB 전용 — cache는 비접촉";
    if (kind === "db") {
      if (!existsSync(crPath)) {
        // CR 파일이 아예 없으면(재실행·손 삭제·이름 오기) drop과 **같은 규율** — 대상이 실재하지 않는 채로
        // 공유 목록을 편집하지 않는다. 잔존만 보고하고(수동 확인) 나머지 정리는 멱등하게 이어간다.
        const probe = planHedgeRemoval();
        hedgeNote = probe.text === null ? "DBS 부재 — 비접촉"
          : `DBS에 '${hedgeEntry}' 잔존 — CR이 없어 헤지 비접촉(수동 확인)`;
      } else {
        if (!/ensure: absent/.test(readFileSync(crPath, "utf8")))
          fail(`Database CR이 아직 ensure: absent가 아니다 (${crPath}) — '--step drop'을 먼저 실행하라`);
        const hedge = planHedgeRemoval();
        writeHedge(hedge);
        hedgeNote = hedge.note;
      }
    }
    if (!DRY) {
      // 원장 행 제거를 파괴적 작업(파일 rm·tombstone) **전에** — totals 프로즈 드리프트/write 실패 시 cleanup abort(F1·F2 버그수정).
      if (layout.kind === "cache") {
        const ledgerPath = `${ROOT}/${layout.paths.ledger}`;
        const component = layout.ledgerRow; // 원장 행 이름 — provision-cache와 같은 커널 값(F1 클래스 소멸)
        if (existsSync(ledgerPath)) {
          let lg = readFileSync(ledgerPath, "utf8");
          // 멱등은 사전 존재 검사로(부재면 이미 정리됨). 존재하면 removeRow→합계 재계산→replaceTotals→write를
          // catch 없이 실행(F2: fail-loud 보존 — 드리프트/write 실패가 purged tombstone 전에 걸린다).
          if (new RegExp(`<!-- ledger:row --> *${component} `).test(lg)) {
            lg = removeRow(lg, component);
            const rows = parseLedgerRows(lg); // F7: 명명 필드(raw 인덱스 금지)
            lg = replaceTotals(lg, rows.reduce((a, r) => a + r.reqMi, 0), rows.reduce((a, r) => a + r.limitMi, 0));
            writeFileSync(ledgerPath, lg);
          }
        }
      }
      // 파일 제거 + 같은 항목을 kustomization에서 등록 해제(둘 다 멱등 — 재실행 안전)
      for (const a of purgeArtifacts) {
        if (existsSync(a.file)) rmSync(a.file, a.dir ? { recursive: true } : {});
        if (existsSync(a.kust)) writeFileSync(a.kust, removeResource(readFileSync(a.kust, "utf8"), a.entry));
      }
      tombs[key] = { state: "purged", backupId, at: new Date().toISOString() };
      writeTombs();
    }
    console.log(JSON.stringify({
      ...plan,
      hedge: hedgeNote,
      action: "cleanup — CR/인스턴스/conn 제거 + kustomization 등록 해제 + tombstone(purged)",
      manual: kind === "db" ? "cluster.yaml managed.roles에서 owner/_ro role 제거는 별도 커밋(워크플로 단계)" : "원장 행 자동 제거됨(cache-<name>)",
    }, null, 2));
    break;
  }
  default:
    fail(`알 수 없는 --step: ${step} (tombstone|drop|verify|cleanup)`);
}
