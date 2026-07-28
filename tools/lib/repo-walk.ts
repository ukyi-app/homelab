// 저장소 스캔 워커 — 가드들이 공유하는 열거 커널.
//
// 문제: 가드 15개가 9가지 방식으로 트리를 걷는다. "레포"의 정의가 4가지(git ls-files / readdirSync /
// 셸 glob / grep -rl)고, YAML 리더가 3가지고, 같은 platform을 보는 두 가드가 서로 다른 제외를 쓴다.
// 이 커널이 그 지식 — repo 열거 의미론 · 제외 어휘 · YAML 파싱 · 열거 바닥값 — 을 한 곳에 모은다.
//
// **스코프는 이름 붙인 고정 집합이다**(조합 가능한 기술자가 아니다). 호출자가 배워야 할 것은 스코프
// 이름뿐이고, 무엇을 뺄지·tracked인지 filesystem인지·바닥값이 얼마인지는 전부 안으로 들어간다.
// 조합 가능한 기술자로 열면 제외 어휘가 호출자로 되밀려 나가 지금의 9벌 중복이 API로 승격된다.
//
// ⚠️ **스코프는 의미론적 필터를 담지 않는다**(design-r1 R-1). 어떤 소비자에겐 맞는 필터가 다른
// 소비자에겐 치명적이다 — audit-orphans는 values.yaml 있는 앱만 보면 되지만 check-app-deploy는 그
// 파일의 **부재**를 잡아야 한다. 열거자가 미리 거르면 위반이 검사 대상에서 사라진다.
// 스코프를 추가할 때마다 물을 것: *"이 필터를 통과 못 한 항목이, 어떤 소비자에게는 찾아내야 할
// 위반은 아닌가?"*
//
// 에러 모드: 미등록 스코프·kind 불일치는 **throw**한다(process.exit·종료문구는 콜사이트 소유 —
// image-pin.ts와 같은 커널 규율).
//
// ⚠️ **열거 바닥값(scan-floor)은 여기 두지 않는다.** 열거자는 "글롭이 깨져 0건"과 "정당하게 0건"을
// 구별할 도메인 지식이 없다 — apps 0개는 첫 온보딩 전의 정상 상태고, 픽스처 트리는 platform/을
// 아예 안 만들기도 한다. 반면 소비자는 이미 자기 도메인에 맞는 바닥값을 갖고 있다
// (check-resource-limits MIN_SCAN=10 · check-image-pins --min-scan 20 · check-alert-rules 30) —
// 그것들은 **의미론적 필터 이후**를 세므로 훨씬 정확하다. 워커 바닥값은 없던 보호를 더하지 않으면서
// 정당한 상태를 고장으로 신고한다(구현 중 픽스처 3곳이 연달아 이 신호를 줬다).
import { execFileSync } from "node:child_process";
import { readFileSync, readdirSync } from "node:fs";
import { type Document, parseAllDocuments } from "yaml";

// 열거 출처. tracked = git ls-files(untracked helm 캐시 platform/*/prod/charts/가 자동 제외된다 —
// 이 지식은 지금까지 scripts/check-image-pins.sh:96 주석에만 있었다). filesystem = 디스크 실재.
type Source = "tracked" | "filesystem";

type ScopeDef = {
  kind: "manifests" | "units";
  source: Source;
  root: string;
  // manifests: 포함할 파일 경로 매치. units: 미사용.
  include: RegExp;
  // units 전용: 추적 경로에서 유닛을 파생하는 패턴. **매치를 강제**한다 — 캡처1=유닛 디렉토리,
  // 캡처2=유닛 이름. 매치 안 되는 경로는 유닛을 만들지 않는다(apps/README.md처럼 유닛 디렉토리를
  // 형성하지 않는 추적 파일이 유닛으로 새어 나오는 실제 버그를 차이 리포트가 잡았다).
  unit?: RegExp;
  // 제외 어휘 — **경로 세그먼트** 매치를 쓴다. 부분 문자열 매치는 과잉 제외한다(구
  // check-resource-limits의 `includes("barman-plugin")`이 정상 파일 cnpg-barman-plugin.yaml까지 걸렀다).
  exclude: RegExp[];
};

// ── 제외 어휘: 무엇을 공유하고 무엇을 나눌 것인가 ──
// **테스트 하네스**는 진짜 공통 개념이다 — platform 스코프들도 producers도 "픽스처를 실물로 세지
// 않는다"는 같은 이유로 뺀다. 그래서 한 곳에 둔다.
// 반면 `charts/`·벤더 규칙은 **스코프마다 답이 다르다**(platform-image-refs는 차트 소스를 일부러
// 포함한다). 공유하면 그 차이가 지워지므로 나눈 채로 둔다.
const TEST_HARNESS: RegExp[] = [
  /(^|\/)tests?\//, // `tests?/`로 단수형도 받는다(방어적 — 현재 추적된 `test/`는 0건)
  /(^|\/)fixtures[^/]*\//, // fixtures-bad 등 접미 변형(check-image-pins가 경험적으로 얻은 형태)
  /(^|\/)test_[^/]*$/, // 파일명 하네스
  /\.bats$/,
];

// platform 전용 벤더 — producers와 공유하지 않는다(레포 전역 스캔엔 무관한 특수 규칙).
const PLATFORM_VENDOR: RegExp[] = [
  /(^|\/)barman-plugin\//, // CNPG barman 벤더 디렉토리(수정 금지)
  /(^|\/)gateway-api-crds\.yaml$/, // 벤더 CRD(1MB, re-vendor 전용)
];

const VENDOR_AND_FIXTURES: RegExp[] = [...PLATFORM_VENDOR, ...TEST_HARNESS];

// `.yml`도 받는다 — check-image-pins.sh(`*.yaml|*.yml`)와 어휘를 맞춘다. 현재 platform 아래
// 추적된 `.yml`은 0건이라 차이 리포트에 안 잡혔다(무영향 확장, 의도).
const YAML_EXT = /\.ya?ml$/;

// 알림 룰이 사는 곳 — `rules` 스코프의 root이자 **SSOT**. 소비자가 "이 경로는 생산자가 아니라
// 검사 대상"이라고 판단할 때도 이 값을 쓴다(CONTRIBUTING: 콜사이트 인라인 사본 금지).
export const RULES_ROOT = "platform/victoria-stack/prod/rules";

const SCOPES: Record<string, ScopeDef> = {
  // "이 파일이 **배포되는 매니페스트**인가" — 차트 소스는 제외한다. 템플릿은 렌더 전이라
  // `{{ }}` 때문에 YAML로 파싱되지 않는다(실측: 공유 차트 deployment.yaml에 파싱 에러 509건).
  "platform-manifests": {
    kind: "manifests",
    source: "tracked",
    root: "platform",
    include: YAML_EXT,
    exclude: [/(^|\/)charts\//, ...VENDOR_AND_FIXTURES],
  },
  // "이 파일이 **이미지 참조**를 담을 수 있는가" — 추적된 차트 소스를 **포함**한다.
  // untracked helm 캐시(platform/*/prod/charts/, gitignored)는 tracked 열거가 자동으로 뺀다.
  // 공급망 가드를 조용히 좁히면 D-2 클래스(차트 내부 이미지 무소유)를 키운다 — 공유 차트
  // values.yaml에 리터럴 이미지가 생기면 잡아야 한다.
  "platform-image-refs": {
    kind: "manifests",
    source: "tracked",
    root: "platform",
    include: YAML_EXT,
    exclude: VENDOR_AND_FIXTURES,
  },
  // 앱 배포 핀(apps 레인)이 사는 파일. 디렉토리 구조 자체가 필터라 별도 제외가 없다.
  "apps-values": {
    kind: "manifests",
    source: "tracked",
    root: "apps",
    include: /\/deploy\/prod\/values\.yaml$/,
    exclude: [],
  },
  // apps 아래 전체 YAML — 파일 단위 질문("이 앱이 NetworkPolicy를 선언했나")용.
  "apps-manifests": {
    kind: "manifests",
    source: "tracked",
    root: "apps",
    include: YAML_EXT,
    exclude: [],
  },
  // 알림 룰 매니페스트. 이 디렉토리를 "무엇으로 볼 것인가"(검사 대상인지 생산자인지)는 소비자가
  // 정한다 — 스코프는 "어디에 있는가"만 안다.
  rules: {
    kind: "manifests",
    source: "tracked",
    root: RULES_ROOT,
    include: YAML_EXT,
    exclude: [],
  },
  // 메트릭을 push할 수 있는 파일 — **레포 전역**. tracked 열거라 .git·node_modules·.terraform·dist가
  // 자동으로 빠진다(구 SKIP_DIRS 6개 중 4개가 추적 파일 0건 — 실측). 남는 charts/만 명시 규칙이다.
  // ⚠️ 룰 디렉토리·린터 자신·PRODUCER_EXEMPT 제외는 **소비자 몫**이다 — 그건 "이 파일이 생산자인가"
  // 라는 도메인 판단이지 "레포에 무엇이 있는가"가 아니다. 스코프가 걸러버리면 다른 소비자가 못 본다.
  producers: {
    kind: "manifests",
    source: "tracked",
    root: "",
    include: /\.(ya?ml|sh|m?[jt]s|py)$/,
    exclude: [/(^|\/)charts\//, ...TEST_HARNESS],
  },
  // 가드 진입점 — "이 레포에서 무엇이 불변식을 강제한다고 주장하는가". 권위 경로 회계(G1)의 열거 대상.
  // 세 계열이 **하나의 스코프**인 이유: 셋 다 "실행되면 불변식을 판정하고 비-0으로 막는" 같은 종류이고,
  // 회계가 묻는 질문("권위 경로가 하나라도 있는가")이 계열과 무관하게 동일하다. 계열별로 쪼개면
  // 소비자가 세 번 열거하고 합치는 사본이 생긴다.
  // ⚠️ `tests/gates/*.sh`를 **포함**한다 — ci.yaml이 직접 부르는 8개 e2e 하네스가 여기 산다. 이들은
  // `*test_*.bats`가 아니라 check-bats-accounting의 도메인 밖이고, 그래서 지금까지 회계 커버리지가 0이었다
  // (9번째가 추가되고 잊혀도, 기존 하나가 삭제되고 파일만 남아도 감지되지 않는다 — 이 스코프가 그 구멍이다).
  //   그래서 공용 TEST_HARNESS 제외를 쓰면 안 된다: 그 어휘의 `tests?/`가 이 8개를 통째로 지운다.
  // ⚠️ `tests/gates/lib/`(하네스가 source하는 프리미티브)는 진입점이 아니라 빠져야 하는데, **별도
  // 제외 규칙을 두지 않는다** — include의 `[^/]+`가 이미 하위 디렉토리를 못 넘는다. 처음엔 명시
  // 제외를 뒀다가 mutation(규칙 삭제 → red여야 함)이 초록이라 죽은 규칙임이 드러나 지웠다.
  // 지키는 것 없는 규칙을 남기면 그게 곧 "아무도 대조하지 않는 주장"이다.
  // ⚠️ **이름 규약은 프록시이고, 강제되지 않는다.** 규약 밖 이름의 새 가드는 조용히 열거에서 빠진다 —
  // 이 스코프가 아는 것은 "이 레포가 가드에 쓰는 이름 모양"뿐이다. 실제 성질(불변식을 판정하고
  // 비-0으로 막는가)로 열거하려면 실행 관측이 필요하고 그건 후속(티켓 08)이다.
  // 최소 방어로 `test_repo-walk.bats`에 **역방향 단언**을 둔다: 규약 모양의 추적 파일은 반드시 열거된다
  // (정방향만 두면 include가 좁아져도 "규약 밖 0건"은 계속 참이라 통과한다 — 실제로 그렇게 뚫렸다).
  guards: {
    kind: "manifests",
    source: "tracked",
    root: "",
    // `tools/`도 `scripts/`와 **같은 접두 쌍**을 받는다 — 비대칭이면 `tools/verify-*.ts`가 조용히
    // 회계 밖에 남는다(실측: `tools/verify-db-marker.ts`가 그렇게 빠져 있었다).
    // 접두(`check-`/`verify-`)뿐 아니라 **접미(`-guard.sh`/`-check.sh`)도 받는다** — 레포가 실제로
    // 쓰는 가드 이름 모양이 둘이다. 접두만 보던 동안 `sops-guard.sh`(ci.yaml required 스텝)와
    // `secret-cert-check.sh`(skip 규약 대상)가 회계 밖에 있었다(리뷰 실측).
    include:
      /^(scripts\/((check|verify)-[^/]+|[^/]+-(guard|check))\.sh|tools\/(check|verify)-[^/]+\.ts|tests\/gates\/[^/]+\.sh)$/,
    exclude: [],
  },
  // "이 파일이 이미지 참조를 담을 수 있는가" — **소유권 회계(G2)** 전용. `platform-image-refs`와
  // 겹쳐 보이지만 **다른 질문에 답한다**:
  //   platform-image-refs = "digest로 핀해야 하는가" → 벤더(barman-plugin·gateway-api CRD)를 **뺀다**.
  //     수정 금지 파일이라 핀 요구의 대상이 아니기 때문이다.
  //   image-ownership     = "누가 이걸 최신으로 유지하는가" → 벤더를 **포함한다**. 수정 금지여도
  //     답이 있어야 하고(re-vendor 절차), 답이 없으면 그게 곧 결함이다. 실측(2026-07-28):
  //     barman-plugin manifest의 `SIDECAR_IMAGE`가 base64로 Secret 안에 tag-only로 들어 있어
  //     핀 게이트·Renovate·grep 어디에도 안 걸린 채 데이터 내구성 경로에 있었다(D-3).
  // apps·ops도 함께 본다 — 소유자 질문은 platform에 국한되지 않는다(ops/는 빌드 소스, apps/는 bump-poll).
  // ⚠️ 테스트 하네스는 뺀다: 픽스처 안의 이미지 문자열은 실물이 아니라 **주장**이라 소유자가 없는 게 정상이다.
  "image-ownership": {
    kind: "manifests",
    source: "tracked",
    root: "",
    include: /^(platform|apps|ops)\/.*\.ya?ml$/,
    exclude: TEST_HARNESS,
  },
  // GHA 워크플로 — "이 레포에서 CI가 무엇을 실행하는가". 준비상태 회계(G-09)의 열거 대상.
  // tracked 열거라 로컬 잔재(에디터 백업·워크트리)가 안 섞이고, 글롭이 깨지면 소비자 바닥값이 잡는다.
  // ⚠️ 제외가 **비어 있는 게 맞다** — `_*.yaml`(내부 reusable)·`reusable-*.yaml`(cross-repo 계약)도
  // 자기 job을 실행하므로 회계 대상이다. 이름으로 거르면 정확히 그 둘이 조용히 회계 밖으로 빠진다.
  workflows: {
    kind: "manifests",
    source: "tracked",
    root: ".github/workflows",
    include: YAML_EXT,
    exclude: [],
  },
  // 앱 유닛. **필수 산출물로 거르지 않는다**(design-r1 R-1) — audit-orphans에겐 values.yaml 필터가
  // 맞지만 check-app-deploy는 그 파일의 **부재**를 잡아야 한다. 의미론적 필터는 소비자 쪽이다.
  // dir은 앱 루트(apps/<app>)다 — 소비자가 필요하면 /deploy/prod를 덧붙인다(컴포넌트 유닛과 동형).
  apps: {
    kind: "units",
    source: "filesystem",
    root: "apps",
    include: /(?:)/,
    unit: /^(apps\/([^/]+))\//,
    exclude: [],
  },
  // platform 컴포넌트 유닛. 공유 차트는 컴포넌트가 아니다(check-skeleton의 README 지도 대상 밖).
  platform: {
    kind: "units",
    source: "filesystem",
    root: "platform",
    include: /(?:)/,
    unit: /^(platform\/([^/]+))\//,
    exclude: [/^platform\/charts\//],
  },
};

export const SCOPE_NAMES = Object.keys(SCOPES);

// 매니페스트 1건. `docs`는 **지연 파싱**이다 — 원시 텍스트만 훑는 소비자(producer 스캔 등)가
// YAML 파싱 비용을 물지 않는다.
export type ManifestEntry = {
  path: string;
  text: string;
  readonly docs: Document[];
};

export type Unit = { name: string; dir: string };

function scopeDef(scope: string, kind: ScopeDef["kind"]): ScopeDef {
  const def = SCOPES[scope];
  if (!def) throw new Error(`repo-walk: 미등록 스코프 '${scope}' (등록: ${SCOPE_NAMES.join(", ") || "없음"})`);
  if (def.kind !== kind) throw new Error(`repo-walk: 스코프 '${scope}'는 ${def.kind} 스코프다`);
  return def;
}

// tracked 열거 — git이 없거나 repo 밖이면 빈 목록. 곧바로 바닥값이 잡으므로 조용히 통과하지 않는다.
// git의 stderr는 버린다: 실패를 여기서 의도적으로 흡수하므로 `fatal: not a git repository`가 모든
// 소비자 출력에 섞이면 노이즈다. 진단은 바닥값 에러가 더 정확한 문구로 대신한다.
function trackedPaths(root: string, sub: string): string[] {
  try {
    // sub가 비면(레포 전역 스코프) pathspec을 아예 주지 않는다 — `git ls-files -- ""`는 빈
    // pathspec이라 아무것도 매치하지 않는다.
    const args = sub ? ["ls-files", "--", sub] : ["ls-files"];
    const out = execFileSync("git", args, {
      cwd: root,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    });
    return out.split("\n").filter(Boolean);
  } catch {
    return [];
  }
}

// filesystem 열거 — 유닛 스코프 전용. 유닛은 "디렉토리가 존재하는가"라는 파일시스템 질문이고,
// 실측상 tracked 파생과 결과가 동일하다(apps 2=2 · platform 16=16). tracked가 사는 곳은 untracked
// helm 캐시(platform/*/prod/charts/)인데 그건 **매니페스트 레벨** 문제라 유닛엔 이득이 없다.
// 반대로 tracked를 유닛에 강요하면 모든 픽스처 트리가 git 레포여야 해서 비용만 크다.
function filesystemDirs(root: string, sub: string): string[] {
  try {
    return readdirSync(`${root}/${sub}`, { withFileTypes: true })
      .filter((e) => e.isDirectory())
      .map((e) => `${sub}/${e.name}/`); // 유닛 패턴이 경계 슬래시를 기대한다
  } catch {
    return [];
  }
}

function enumerate(def: ScopeDef, root: string): string[] {
  const raw = def.source === "tracked" ? trackedPaths(root, def.root) : filesystemDirs(root, def.root);
  return raw
    .filter((p) => def.include.test(p))
    .filter((p) => !def.exclude.some((re) => re.test(p)))
    .sort();
}

// 스코프의 매니페스트를 열거한다. `docs`는 최초 접근 시 파싱하고 캐시한다.
export function walkManifests(scope: string, root = "."): ManifestEntry[] {
  const def = scopeDef(scope, "manifests");
  const paths = enumerate(def, root);
  return paths.map((path) => {
    const text = readFileSync(`${root}/${path}`, "utf8");
    let cached: Document[] | undefined;
    return {
      path,
      text,
      get docs(): Document[] {
        if (!cached) cached = parseAllDocuments(text);
        return cached;
      },
    };
  });
}

// 스코프의 유닛(앱/컴포넌트 디렉토리)을 열거한다. 미등록 스코프·kind 불일치는 조용한 빈 배열이
// 아니라 throw다 — 조용히 비면 소비자가 vacuous하게 통과한다.
export function listUnits(scope: string, root = "."): Unit[] {
  const def = scopeDef(scope, "units");
  if (!def.unit) throw new Error(`repo-walk: 유닛 스코프 '${scope}'에 unit 패턴이 없다`);
  const seen = new Map<string, Unit>();
  for (const p of enumerate(def, root)) {
    const m = def.unit.exec(p);
    if (!m) continue; // 유닛 디렉토리를 형성하지 않는 경로(예: apps/README.md)
    if (!seen.has(m[1])) seen.set(m[1], { name: m[2], dir: m[1] });
  }
  const units = [...seen.values()].sort((a, b) => (a.dir < b.dir ? -1 : 1));
  return units;
}

// ── CLI: 셸 가드가 열거 결과만 받아 쓰는 진입점 ──
// 셸 가드는 TS로 이관하지 않는다 — CONTRIBUTING이 "라인 지향 검사(grep/yq/jq 필터)"를 셸의 명시된
// 영역으로 규정하고, check-app-deploy.sh:21은 "yq는 버전차 함정이라 값 추출은 sed/grep으로"라는
// 의도적 선택을 적어 뒀다. 셸은 자기 추출 로직을 유지하고 **열거·제외·바닥값만** 받는다 —
// 셸이 추가 제외를 하지 않으므로 제외 어휘의 사본이 원리적으로 존재하지 않게 된다.
// 종료코드는 tools/lib/cli.ts 규약: 0=성공 · 1=검증(열거 붕괴) · 2=사용법/미등록 스코프.
if (import.meta.main) {
  const argv = process.argv.slice(2);
  let mode: "manifests" | "units" | "" = "";
  let scope = "";
  let root = ".";
  for (let i = 0; i < argv.length; i += 2) {
    const [flag, val] = [argv[i], argv[i + 1]];
    if (val === undefined) { console.error(`값 없는 플래그: ${flag}`); process.exit(2); }
    if (flag === "--manifests") { mode = "manifests"; scope = val; }
    else if (flag === "--units") { mode = "units"; scope = val; }
    else if (flag === "--root") root = val;
    else { console.error(`알 수 없는 플래그: ${flag}\n허용: --manifests <scope> | --units <scope> | --root <path>`); process.exit(2); }
  }
  if (!mode) { console.error("사용법: repo-walk.ts --manifests <scope> | --units <scope> [--root <path>]"); process.exit(2); }
  // 미등록 스코프(사용법 오류, exit 2)와 열거 붕괴(검증 실패, exit 1)를 구분해 보고한다.
  if (!SCOPES[scope]) { console.error(`미등록 스코프 '${scope}' (등록: ${SCOPE_NAMES.join(", ")})`); process.exit(2); }
  try {
    const paths = mode === "manifests"
      ? walkManifests(scope, root).map((e) => e.path)
      : listUnits(scope, root).map((u) => u.dir);
    if (paths.length) console.log(paths.join("\n"));
  } catch (e) {
    console.error(e instanceof Error ? e.message : String(e));
    process.exit(1);
  }
}
