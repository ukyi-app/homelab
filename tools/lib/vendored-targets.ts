// 동봉 계약(tools/vendored-contract.json) target 행의 **앱 축** 편집 커널 — create-app(추가)/
// teardown-app(제거) 공용. digest-exporter APPS·pgdump 헤지 DBS의 형제이고, 같은 자리에 산다:
// 앱-**외부** 표면이라 app-surface module의 소관이 아니고(그쪽은 apps/<app>/ 디렉토리 통째 rm이
// 대칭을 구조로 보장한다), 각 표면의 SSOT 헬퍼가 add/remove 쌍으로 대칭을 진다.
//
// 병(라이브 실측): 매니페스트 targets의 앱 축은 손 열거가 아니라 `apps/<app>/deploy/prod/source-repo`
// 파생 집합과 **등식**으로 대조된다(contract-drift-check.ts의 reconcileRoster — 초과=stale-target ·
// 부족=missing-target 둘 다 drift). 그래서 온보딩(#691)·철거(#698) 때마다 사람이 이 파일에 행 2개를
// 넣고 뺐고, 두 번 다 잊었다가 gate red로 알았다(비용 = gate 1사이클 ≈11분 + 손 편집).
//
// 이 커널이 소유하는 것 = **앱 행 문법 전부**:
//   · 행 위치 — 각 vendored 항목 targets의 말미(템플릿 앵커 행 뒤).
//   · path   — `tools/<source의 파일명>`. 앱 레포의 사본은 레포 루트 `tools/` 하나에 산다
//              (템플릿만 `scaffold/common/tools/…`라 자기 행의 path를 그대로 물려줄 수 없다).
//   · ref    — `main`. 매니페스트 어디에도 브랜치를 고를 축이 없고 현 계약은 전부 main이다.
//   · normalize — **같은 source의 기존 행에서 상속**한다. 정규화 모드는 파일 종류의 성질이지
//              대상 레포의 성질이 아니다(cert=exact · .mts=typescript). 유도 불가면 throw.
//   · 직렬화 — 2칸 들여쓰기 + 말미 개행. 실 SSOT 파일이 이미 이 형태라 왕복이 바이트 동일이다
//              (test_vendored-targets의 대칭 레인이 실 파일 위에서 그것을 잰다).
// 부재 판정(hasAppTargets)은 편집과 **같은 문법**을 지난다 — 항목 부재는 false(호출부의 정상
// no-op), 포맷 드리프트는 throw(고장). 손 정규식은 그 둘을 같은 무성 경로로 뭉갠다.
import { basename } from "node:path";

// 매니페스트 형상 SSOT — contract-drift-check.ts가 여기서 가져다 쓴다(타입 두 벌 금지).
export type Norm = "typescript" | "exact";
export type Target = { repo: string; ref: string; path: string; normalize: Norm };
export type Entry = { source: string; targets: Target[] };
export type Manifest = { owner: string; scaffoldRepos?: string[]; vendored: Entry[] };

// 앱 레포 사본의 ref. 상수인 근거는 위 헤더(브랜치 선택 축이 계약에 없다).
const APP_REF = "main";

// 파싱 + **편집 가능성** 검증. 편집 축(vendored)만 본다 — owner/scaffoldRepos/_note/_roster는
// 이 커널의 대상이 아니라 **보존 대상**이지만, owner는 매니페스트 계약의 필수 키라 타입이
// 거짓말하지 않도록 함께 확인한다.
function parse(text: string): Manifest {
  let mf: unknown;
  try { mf = JSON.parse(text); } catch (e) {
    throw new Error(`vendored-contract 파싱 실패 — ${e instanceof Error ? e.message : String(e)}`);
  }
  const m = mf as Partial<Manifest> | null;
  if (typeof m?.owner !== "string" || !Array.isArray(m?.vendored))
    throw new Error("vendored-contract 형상 아님(owner 문자열 + vendored 배열 필요) — 포맷 드리프트로 갱신 불가");
  // ⚠️ 0건은 "추가/제거할 것이 없다"가 아니라 **열거 붕괴**다. 조용히 no-op으로 두면 앱은
  //    생성되는데 행만 없어, 다음 리컨실 주기가 missing-target으로 발화한다(이 커널이 없애는 실패).
  if (m.vendored.length === 0)
    throw new Error("vendored 항목 0건 — 편집할 축이 없다(열거 붕괴)");
  for (const e of m.vendored) {
    if (typeof e?.source !== "string" || !Array.isArray(e?.targets))
      throw new Error("vendored 항목에 source(문자열)·targets(배열)가 없다 — 포맷 드리프트로 갱신 불가");
  }
  return m as Manifest;
}

const serialize = (mf: Manifest) => JSON.stringify(mf, null, 2) + "\n";

// 한 vendored 항목이 이 앱에 대해 가져야 할 행. normalize는 그 항목의 기존 행에서 상속한다 —
// 값이 갈리거나(모드 혼재) 기존 행이 0건이면 유도 불가라 throw다(임의 기본값을 고르면 cert가
// typescript로 느슨해지는 방향의 조용한 계약 약화가 가능해진다).
function rowFor(e: Entry, app: string): Target {
  const norms = [...new Set(e.targets.map((t) => t.normalize))];
  if (norms.length !== 1)
    throw new Error(`${e.source}: normalize를 기존 행에서 유도할 수 없다(기존 target ${e.targets.length}건, 값 ${JSON.stringify(norms)})`);
  return { repo: app, ref: APP_REF, path: `tools/${basename(e.source)}`, normalize: norms[0] };
}

// 이 앱이 가져야 할 행 목록(source를 붙인 관측용 투영). 파일을 만지지 않는다 — create-app의
// plan/dry-run이 이것을 싣는다(계획 = 행동의 예고).
export function appTargetRows(text: string, app: string): (Target & { source: string })[] {
  return parse(text).vendored.map((e) => ({ source: e.source, ...rowFor(e, app) }));
}

// 멱등 추가 — 이미 그 앱 행이 있는 항목은 **손대지 않는다**(digest-exporter addApp과 같은 계약).
export function addAppTargets(text: string, app: string): string {
  const mf = parse(text);
  for (const e of mf.vendored) {
    if (e.targets.some((t) => t.repo === app)) continue;
    e.targets.push(rowFor(e, app));
  }
  return serialize(mf);
}

// 멱등 제거. 앵커(템플릿) 행까지 지워 targets가 비는 것은 **거부**한다 — 그러면 그 source의 벤더
// 감시가 통째로 꺼지는데 로스터 등식은 앱 축만 보므로 여전히 성립한다(계약이 조용히 사라지는
// 유일한 경로). 매니페스트 자신의 불변식(all targets length > 0)과 같은 선이다.
export function removeAppTargets(text: string, app: string): string {
  const mf = parse(text);
  for (const e of mf.vendored) {
    const kept = e.targets.filter((t) => t.repo !== app);
    if (kept.length === 0)
      throw new Error(`${e.source}: '${app}' 행을 빼면 target이 0건이 된다 — 앵커 행은 앱 행이 아니다(계약이 꺼진다)`);
    e.targets = kept;
  }
  return serialize(mf);
}

// 존재 판정 — 편집과 같은 문법. 부재는 false(정상 no-op), 포맷 드리프트는 throw(고장).
export function hasAppTargets(text: string, app: string): boolean {
  return parse(text).vendored.some((e) => e.targets.some((t) => t.repo === app));
}
