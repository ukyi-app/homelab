// 앱 표면 module — "앱은 어떤 파일들로 이루어지는가"의 유일 선언(lib-convergence d4 · CONTEXT.md
// 「앱 표면」). 종전에는 create-app이 표면 6종을 손조립으로 쓰고 경로 리터럴(`apps/<app>/deploy/prod/…`)이
// 소비자 여럿에 흩어져 있었다 — 기록 집합의 **선언**이 없어서, 표면이 늘어도 그 사실을 아무 데서도
// 셀 수 없었다. 철거의 대칭 자체는 종전에도 디렉토리 통째 rm이라 자명했고 지금도 그렇다(removeAppSurface).
// 이 module이 새로 주는 것은 경로 SSOT + 기록 집합의 선언이며, test_app-surface.bats의 집합 동일성
// 단언(기록 목록 ↔ 디스크 실측)이 그 선언의 정확성을 잰다.
//
// 함수 API 형태다(표면 목록의 데이터화는 기각 — 표면마다 쓰기 로직이 달라 데이터에 욱여넣게 된다).
// autoDeploy 값 해석은 descriptorAutoDeploy(image-pin) 하나를 재사용한다 — 정확히 boolean true만
// 승인이고, 부재·파손은 null(부재)로 접는다(fail-closed 의미 부여는 소비자 몫).
// 앱-외부 표면(apps.json 행·메모리 원장 행·digest-exporter APPS 항목)은 이 module의 소관이 아니다 —
// 각자의 SSOT 헬퍼(digest-exporter.ts·ledger-budget.ts)와 parity 게이트가 지킨다.
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { parse as parseYaml, stringify as toYaml } from "yaml";
import { descriptorAutoDeploy } from "./image-pin.ts";

// ── 경로 SSOT ──────────────────────────────────────────────────────────────────────────────────
// appRel = 레포-상대(와이어·계약 문자열용 — plan.writePath·verbs surfacePath가 이 형태를 실어 나른다).
// appPaths = 파일시스템 접근용(root 결합 — root는 정규화하지 않으므로 trailing slash 없는 형태가
// 호출부 계약이다). 둘은 appRel 하나에서 파생된다 — 두 벌이 드리프트할 자리가 없다.
export type AppRelPaths = {
  dir: string; prod: string;
  values: string; sourceRepo: string; bindings: string; kustomization: string; activation: string;
  sealed: (file: string) => string;
};

export function appRel(app: string): AppRelPaths {
  const dir = `apps/${app}`;
  const prod = `${dir}/deploy/prod`;
  return {
    dir, prod,
    values: `${prod}/values.yaml`,
    sourceRepo: `${prod}/source-repo`,
    bindings: `${prod}/.bindings.json`,
    kustomization: `${prod}/kustomization.yaml`,
    activation: `${prod}/.activation`,
    sealed: (file: string) => `${prod}/${file}`,
  };
}

export function appPaths(root: string, app: string): AppRelPaths {
  const r = appRel(app);
  return {
    dir: `${root}/${r.dir}`, prod: `${root}/${r.prod}`,
    values: `${root}/${r.values}`, sourceRepo: `${root}/${r.sourceRepo}`, bindings: `${root}/${r.bindings}`,
    kustomization: `${root}/${r.kustomization}`, activation: `${root}/${r.activation}`,
    sealed: (file: string) => `${root}/${r.sealed(file)}`,
  };
}

// ── 읽기 — 부재/파손 = null(값이 아니라 부재다) ────────────────────────────────────────────────
// autoDeploy: bindings 부재/파손이면 null, 실재하면 descriptorAutoDeploy 접기(true만 승인 — "yes"·1·
// 누락 키는 전부 false). 승인 게이트 의미(부재=propose-pr)는 bump-plan.laneFor가, 표시 의미(미기록)는
// status가 각자 이 원시 사실 위에서 소유한다.
export type AppSurfaceRead = {
  values: Record<string, unknown> | null;
  autoDeploy: boolean | null;
  sourceRepo: string | null;
};

export function readAppSurface(root: string, app: string): AppSurfaceRead {
  const p = appPaths(root, app);
  let values: Record<string, unknown> | null = null;
  try { values = (parseYaml(readFileSync(p.values, "utf8")) ?? {}) as Record<string, unknown>; } catch { /* 부재/파손 = null */ }
  let bindings: { autoDeploy?: unknown } | null = null;
  try { bindings = JSON.parse(readFileSync(p.bindings, "utf8")); } catch { /* 부재/파손 = null */ }
  let sourceRepo: string | null = null;
  try {
    const s = readFileSync(p.sourceRepo, "utf8").trim();
    sourceRepo = s.length > 0 ? s : null;
  } catch { /* 부재(인레포 앱) = null */ }
  return { values, autoDeploy: bindings === null ? null : descriptorAutoDeploy(bindings), sourceRepo };
}

// ── 쓰기 — create가 쓰는 표면 집합의 유일 선언 ─────────────────────────────────────────────────
// 반환은 기록한 **레포-상대 경로 목록**(관측용). 이빨의 범위는 정확히 이 함수 본문이다: 여기서
// 파일을 쓰고 목록에 올리지 않으면(또는 그 반대) module 테스트의 기록↔실측 대조가 red다.
// 콜사이트가 이 module 밖에서 표면을 직접 쓰는 것까지 잡지는 못한다 — 그 경계는 경로 SSOT
// (appRel/appPaths) 경유 규율이 지킨다.
export type AppSurfaceFacts = {
  values: unknown;                                          // values.yaml(YAML 직렬화)
  sourceRepo: string;                                       // bump-poll의 발신 레포 바인딩(<owner>/<repo>)
  bindings: { autoDeploy: boolean };                        // 승인 정책 레지스트리(poll-ghcr의 유일 소스)
  sealed?: { file: string; bytes: string | Uint8Array } | null; // 봉인본 — 원본 바이트 그대로(checksum 정합)
  // 공개 앱의 재노출 게이트 마커. 함수형이면 **다른 표면을 전부 기록한 뒤** 평가한다 — 마커의
  // surfaceHash는 디스크에 실재하는 표면(단, .activation 제외 canonical)을 해시해야 하기 때문이다.
  // (객체 | 콜백 유니온을 명시해야 컴파일 층위에도 계약이 남는다 — unknown과의 유니온은 붕괴한다.)
  activation?: Record<string, unknown> | (() => Record<string, unknown> | null | undefined) | null;
};

export function writeAppSurface(root: string, app: string, facts: AppSurfaceFacts): string[] {
  const rel = appRel(app);
  const p = appPaths(root, app);
  const written: string[] = [];
  mkdirSync(p.prod, { recursive: true });
  writeFileSync(p.values, toYaml(facts.values));
  written.push(rel.values);
  writeFileSync(p.sourceRepo, `${facts.sourceRepo}\n`);
  written.push(rel.sourceRepo);
  writeFileSync(p.bindings, JSON.stringify(facts.bindings, null, 2) + "\n");
  written.push(rel.bindings);
  // kustomization은 봉인본 유무와 무관하게 항상 필요하다(appset source #3가 kustomize 렌더 —
  // 없으면 values.yaml을 매니페스트로 파싱해 "groupVersion shouldn't be empty"로 죽는다).
  writeFileSync(p.kustomization, toYaml({
    apiVersion: "kustomize.config.k8s.io/v1beta1", kind: "Kustomization",
    namespace: "prod",
    ...(facts.sealed ? { resources: [facts.sealed.file] } : {}),
  }));
  written.push(rel.kustomization);
  if (facts.sealed) {
    writeFileSync(p.sealed(facts.sealed.file), facts.sealed.bytes); // 원본 바이트 그대로(checksum과 정합)
    written.push(rel.sealed(facts.sealed.file));
  }
  if (facts.activation != null) {
    const marker = typeof facts.activation === "function" ? facts.activation() : facts.activation;
    if (marker != null) { // 콜백의 null 반환 = 마커 없음(undefined를 직렬화해 파일을 깨뜨리지 않는다)
      writeFileSync(p.activation, JSON.stringify(marker, null, 2) + "\n");
      written.push(rel.activation);
    }
  }
  return written;
}

// ── 제거 — teardown이 지우는 집합 = 앱 디렉토리 전체(위 write가 뭘 추가하든 구조적으로 다 지운다) ──
// 멱등: 이미 없으면 false(조용) — teardown-app의 "이미 없어도 0 종료" 계약을 받친다.
export function removeAppSurface(root: string, app: string): boolean {
  const dir = appPaths(root, app).dir;
  if (!existsSync(dir)) return false; // existsSync는 반환값 계산용 — 삭제 자체는 force가 멱등을 보장한다
  rmSync(dir, { recursive: true, force: true });
  return true;
}
