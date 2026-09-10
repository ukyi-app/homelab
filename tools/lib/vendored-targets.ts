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
//              ⚠️ **유도는 추측이라 뒷받침을 요구한다**: 그 항목의 기존 행 중 최소 하나가 같은
//              꼬리(`…/tools/<파일명>`)를 가져야 하고, 유도된 path는 항목 간 유일해야 한다.
//              틀린 유도는 라이브 fetch에서 404가 되는데 classifyStatus가 그것을
//              absent-or-private로 접어 **drift로 승격하지 않는다** — 로스터 등식은 repo 이름만
//              보므로 그 행은 조용히 감시 밖이 된다(발견이 아니라 침묵이다).
//   · ref    — `main`. 매니페스트 어디에도 브랜치를 고를 축이 없고 현 계약은 전부 main이다.
//              (그 상수 가정은 test_vendored-targets의 정확 문자열 레인이 잠근다.)
//   · normalize — **같은 source의 기존 행에서 상속**한다. 정규화 모드는 파일 종류의 성질이지
//              대상 레포의 성질이 아니다(cert=exact · .mts=typescript). 유도 불가면 throw.
//   · 직렬화 — 2칸 들여쓰기 + 말미 개행. 실 SSOT 파일이 이미 이 형태라 왕복이 바이트 동일이다
//              (test_vendored-targets의 대칭 레인이 실 파일 위에서 그것을 잰다).
// 소유가 문법 **전부**이므로 추가는 존재 확인이 아니라 **정본화**다: 이미 있는 앱 행이 유도와
// 어긋나면 그 행을 정본으로 되돌린다. 존재만 보고 건너뛰면 plan(PR 본문 JSON)이 파일에 없는 행을
// 예고해 승인자가 읽는 계획과 diff가 갈리고, 그 드리프트를 고칠 경로가 아무 데도 없다.
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
    // ⚠️ target **원소**의 형상까지 본다. 종전엔 `Target` 타입이 런타임 증인 없이 참을 주장했고,
    //    normalize 상속(rowFor)이 값 집합의 **크기**만 재서 `undefined`(키 부재)나 `"Exact"`(오타)가
    //    길이 1로 통과했다. 그렇게 만든 앱 행을 소비자(contract-drift-check의 normalize())는
    //    `mode === "exact"`가 아니라는 이유로 **typescript(느슨한 쪽)** 로 접는다 — cert 사본의
    //    바이트 위변조가 원본과 같다고 읽히는 방향이다(이 파일 헤더가 스스로 경계한 그 방향).
    //    targets **0건**은 여기서 안 잡는다: 그 진단은 rowFor의 "normalize 유도 불가"가 소유한다.
    for (const t of e.targets as Partial<Target>[]) {
      if (typeof t?.repo !== "string" || typeof t?.ref !== "string" || typeof t?.path !== "string")
        throw new Error(`${e.source}: target 행에 repo/ref/path(문자열)가 없다 — 포맷 드리프트로 갱신 불가`);
      if (t.normalize !== "typescript" && t.normalize !== "exact")
        throw new Error(`${e.source}: target 행의 normalize가 typescript|exact가 아니다(${JSON.stringify(t.normalize)}) — 앱 행이 느슨한 쪽으로 상속된다`);
    }
  }
  // ⚠️ 유도가 basename이므로 서로 다른 source 둘이 같은 파일명이면 앱 레포에서 **한 경로**를
  //    다툰다 — 두 항목이 같은 사본을 감시하고 어느 쪽도 red가 아니다(둘 다 fetch에 성공한다).
  //    편집 함수가 아니라 여기(parse)에 두는 이유: 커널의 모든 진입점(부재 판정 포함)이 같은
  //    문법을 지나야 한다. 이 매니페스트를 이 커널이 **소유할 수 있는가**의 판정이다.
  const seen = new Map<string, string>();
  for (const e of m.vendored) {
    const f = basename(e.source);
    const prev = seen.get(f);
    if (prev !== undefined)
      throw new Error(`${prev} · ${e.source}: 앱 행 path가 tools/${f} 하나로 충돌한다 — 유도(basename)가 두 source를 가른다`);
    seen.set(f, e.source);
  }
  return m as Manifest;
}

const serialize = (mf: Manifest) => JSON.stringify(mf, null, 2) + "\n";

// 한 vendored 항목이 이 앱에 대해 가져야 할 행. normalize는 그 항목의 기존 행에서 상속한다 —
// 값이 갈리거나(모드 혼재) 기존 행이 0건이면 유도 불가라 throw다(임의 기본값을 고르면 cert가
// typescript로 느슨해지는 방향의 조용한 계약 약화가 가능해진다).
// ⚠️ 여기서 재는 것은 **크기**뿐이다 — 값이 `Norm`인지는 parse()가 이미 잠갔다(그게 없으면
//    `[undefined]`·`["Exact"]`도 길이 1이라 통과해 그 약화가 상속으로 열린다).
function rowFor(e: Entry, app: string): Target {
  const norms = [...new Set(e.targets.map((t) => t.normalize))];
  if (norms.length !== 1)
    throw new Error(`${e.source}: normalize를 기존 행에서 유도할 수 없다(기존 target ${e.targets.length}건, 값 ${JSON.stringify(norms)})`);
  // path 유도의 뒷받침 — 기존 행 중 최소 하나가 같은 꼬리를 가져야 한다. 앵커(템플릿) 행이
  // `scaffold/common/tools/<파일명>`이라 그 조건을 만족하고, `docs/policy.md`처럼 tools/ 밖에
  // 사는 source는 여기서 fail-loud로 걸린다(종전엔 `tools/policy.md`를 조용히 지어냈다).
  // ⚠️ **전칭이 아니라 존재**다: 어긋난 **앱** 행은 거부가 아니라 아래 addAppTargets의 정본화가
  //    맡는다(도구가 쓰는 축을 도구가 고친다). 뒷받침이 0건이면 유도할 근거 자체가 없다.
  const path = `tools/${basename(e.source)}`;
  if (!e.targets.some((t) => t.path === path || t.path.endsWith(`/${path}`)))
    throw new Error(`${e.source}: 앱 행 path '${path}'를 뒷받침하는 기존 행이 없다 — 유도가 추측이 된다(404는 drift로 승격되지 않는다)`);
  return { repo: app, ref: APP_REF, path, normalize: norms[0] };
}

// 이 앱이 가져야 할 행 목록(source를 붙인 관측용 투영). 파일을 만지지 않는다 — create-app의
// plan/dry-run이 이것을 싣는다(계획 = 행동의 예고).
export function appTargetRows(text: string, app: string): (Target & { source: string })[] {
  return parse(text).vendored.map((e) => ({ source: e.source, ...rowFor(e, app) }));
}

// 멱등 추가 + **정본화**. 없으면 말미에 붙이고, 있으면 유도한 정본으로 교체한다(자리 보존).
// 정본과 같으면 결과 바이트가 같으므로 멱등이고, 호출부는 바이트 동일이면 파일을 만지지 않는다.
// ⚠️ digest-exporter addApp의 "있으면 건너뛴다"와 갈리는 지점이다. 거기서는 항목이 이름 하나라
//    존재=정본이지만, 여기 앱 행은 ref·path·normalize를 더 갖는다 — 존재만 보면 어긋난 행이
//    그대로 남고, appTargetRows가 낸 plan(PR 본문)은 파일에 없는 행을 예고한다.
export function addAppTargets(text: string, app: string): string {
  const mf = parse(text);
  for (const e of mf.vendored) {
    const want = rowFor(e, app);
    const i = e.targets.findIndex((t) => t.repo === app);
    if (i < 0) e.targets.push(want);
    else e.targets[i] = want;
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
