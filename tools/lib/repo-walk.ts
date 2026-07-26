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
// 에러 모드: 미등록 스코프와 열거 붕괴는 **throw**한다(process.exit·종료문구는 콜사이트 소유 —
// image-pin.ts와 같은 커널 규율). 조용히 빈 배열을 주면 소비자가 vacuous하게 통과한다.
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { type Document, parseAllDocuments } from "yaml";

// 열거 출처. tracked = git ls-files(untracked helm 캐시 platform/*/prod/charts/가 자동 제외된다 —
// 이 지식은 지금까지 scripts/check-image-pins.sh:96 주석에만 있었다). filesystem = 디스크 실재.
type Source = "tracked" | "filesystem";

type ScopeDef = {
  kind: "manifests" | "units";
  source: Source;
  root: string;
  // 포함 조건(경로 전체에 대한 매치).
  include: RegExp;
  // 제외 어휘 — **경로 세그먼트** 매치를 쓴다. 부분 문자열 매치는 과잉 제외한다(구
  // check-resource-limits의 `includes("barman-plugin")`이 정상 파일 cnpg-barman-plugin.yaml까지 걸렀다).
  exclude: RegExp[];
  // 열거 바닥값 — **열거 붕괴**(글롭이 깨져 0건)만 본다. 레포 규모 단언이 아니다:
  // 실 레포 크기에 맞춘 상수를 박으면 모든 픽스처 트리가 깨지고, 소비자는 이미 자기 도메인에 맞는
  // 바닥값을 갖는다(check-resource-limits의 MIN_SCAN=10은 **워크로드 kind 매치 이후** 바닥값이다).
  // 소비자의 의미론적 필터 이후에 생기는 vacuity도 소비자 책임이다(design-r1 R-1).
  floor: number;
};

// 벤더·픽스처 제외 — 두 platform 스코프가 공유한다. 차트 규칙만 스코프마다 다르다.
const VENDOR_AND_FIXTURES: RegExp[] = [
  /(^|\/)barman-plugin\//, // CNPG barman 벤더 디렉토리(수정 금지)
  // 픽스처 매니페스트를 실 워크로드로 세지 않는다. `tests?/`로 단수형도 받는다(방어적 확장 —
  // 현재 platform 아래 `test/`는 0건이라 무영향).
  /(^|\/)tests?\//,
  /(^|\/)fixtures[^/]*\//, // fixtures-bad 등 접미 변형 포함(check-image-pins가 경험적으로 얻은 형태)
  /(^|\/)gateway-api-crds\.yaml$/, // 벤더 CRD(1MB, re-vendor 전용)
];

// `.yml`도 받는다 — check-image-pins.sh(`*.yaml|*.yml`)와 어휘를 맞춘다. 현재 platform 아래
// 추적된 `.yml`은 0건이라 차이 리포트에 안 잡혔다(무영향 확장, 의도).
const YAML_EXT = /\.ya?ml$/;

const SCOPES: Record<string, ScopeDef> = {
  // "이 파일이 **배포되는 매니페스트**인가" — 차트 소스는 제외한다. 템플릿은 렌더 전이라
  // `{{ }}` 때문에 YAML로 파싱되지 않는다(실측: 공유 차트 deployment.yaml에 파싱 에러 509건).
  "platform-manifests": {
    kind: "manifests",
    source: "tracked",
    root: "platform",
    include: YAML_EXT,
    exclude: [/(^|\/)charts\//, ...VENDOR_AND_FIXTURES],
    floor: 1,
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
    floor: 1,
  },
  // 앱 배포 핀(apps 레인)이 사는 파일. 디렉토리 구조 자체가 필터라 별도 제외가 없다.
  "apps-values": {
    kind: "manifests",
    source: "tracked",
    root: "apps",
    include: /\/deploy\/prod\/values\.yaml$/,
    exclude: [],
    floor: 1,
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
    const out = execFileSync("git", ["ls-files", "--", sub], {
      cwd: root,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    });
    return out.split("\n").filter(Boolean);
  } catch {
    return [];
  }
}

function enumerate(def: ScopeDef, root: string): string[] {
  const raw = def.source === "tracked" ? trackedPaths(root, def.root) : [];
  return raw
    .filter((p) => def.include.test(p))
    .filter((p) => !def.exclude.some((re) => re.test(p)))
    .sort();
}

function enforceFloor(scope: string, def: ScopeDef, n: number): void {
  if (n >= def.floor) return;
  throw new Error(
    `repo-walk: 스코프 '${scope}' 열거 ${n}건 < 바닥값 ${def.floor} — 열거 붕괴 의심(경로 재배치·git 밖 실행?)`,
  );
}

// 스코프의 매니페스트를 열거한다. `docs`는 최초 접근 시 파싱하고 캐시한다.
export function walkManifests(scope: string, root = "."): ManifestEntry[] {
  const def = scopeDef(scope, "manifests");
  const paths = enumerate(def, root);
  enforceFloor(scope, def, paths.length);
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

// 스코프의 유닛(앱/컴포넌트 디렉토리)을 열거한다. 유닛 스코프는 아직 등록되지 않았다 —
// 미등록 스코프는 조용한 빈 배열이 아니라 throw다.
export function listUnits(scope: string, root = "."): Unit[] {
  const def = scopeDef(scope, "units");
  const paths = enumerate(def, root);
  enforceFloor(scope, def, paths.length);
  return paths.map((p) => ({ name: p.split("/").pop() ?? p, dir: p }));
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
