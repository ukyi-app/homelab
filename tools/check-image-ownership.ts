// G2 — 이미지 **소유권 회계**. "이 이미지를 누가 최신으로 유지하고, 누가 immutable 핀을 보증하는가".
//
// `scripts/check-image-pins.sh`와 **다른 질문**이다. 저건 "digest로 핀됐는가"를 묻고, 여긴 "그 digest를
// **누가 갱신하는가**"를 묻는다. 둘은 독립이다 — 라이브 실측(2026-07-28)이 그걸 보여줬다:
// `pg-tools:18-rclone`이 두 digest로 갈려 있었는데(D-1) 핀 게이트는 **둘 다 통과**시켰다(핀의 *존재*만
// 보고 *일치*는 안 본다). 갱신 도구는 하드코딩 4파일만 재핀하면서 성공을 보고했고, 그 목록을 다시
// 하드코딩한 bats가 "단일 digest"를 확인해 초록이었다 — 세 산출물이 서로는 일치하고 레포와는 어긋났다.
//
// **두 축을 분리한다**(이게 이 회계의 핵심 모델):
//   · freshness 소유자 — 누가 새 버전을 가져오는가(Renovate·bump-poll·repin·수동 re-vendor).
//   · digest 소유자   — 누가 immutable 핀을 보증하는가.
// 둘은 자주 다르다. helm 차트 내부 기본 이미지는 **차트 버전이 Renovate 소유**라 freshness는 있지만,
// 렌더 시점에 mutable tag로 해석되므로 **digest 소유자가 없다**. "Renovate 관할"이라고만 적으면 그
// 차이가 지워진다 — `check-image-pins.sh` 헤더가 실제로 그렇게 적혀 있었고 그건 절반만 참이었다.
//
// **소유자 없음은 결함이 아니라 선언 대상이다**(G-09 준비상태 원장과 같은 규율): `policy/image-ownership.json`에
// 근거·freshness 채널·owner_action과 함께 적는다. **선언되지 않은 무소유는 통과할 수 없다.**
//
// ⚠️ **벤더 파일을 포함해 본다.** `platform-image-refs` 스코프는 벤더를 빼는데(수정 금지라 핀 요구
// 대상이 아니다) 소유권 질문은 수정 금지 파일에도 답이 있어야 한다. 실측: barman-plugin manifest의
// `SIDECAR_IMAGE`가 **base64로 Secret 안에** tag-only로 들어 있어 핀 게이트·Renovate·`image:` grep
// 어디에도 안 걸린 채 데이터 내구성 경로에 있었다(D-3). 그래서 숨은 참조도 따로 스캔한다.
//
// 종료코드: tools/lib/cli.ts 규약(0=통과 · 1=검증 실패 · 2=사용법).
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { typedFlags } from "./lib/cli.ts";
import { walkManifests } from "./lib/repo-walk.ts";
import { guardMain, takeFloors } from "./lib/scan-floor.ts";
import { readLedger } from "./lib/policy-ledger.ts";

const POLICY_PATH = "policy/image-ownership.json";
const RENOVATE_PATH = "renovate.json";

// `image:`/`imageName:` 스칼라. 앵커해서 `logo_image:`·경로 속 부분매치를 막는다(핀 게이트와 같은 어휘).
const IMG_KEY = /^[ \t]*(?:-[ \t]+)?(image|imageName):[ \t]*["']?([a-z0-9][^\s"'#]*)/gm;
// 이미지처럼 생긴 문자열 — 숨은(base64) 참조 판정용. 최소 `<호스트|경로>/<이름>:<태그>` 또는 `<이름>:<태그>`.
const IMG_SHAPE = /^[a-z0-9][a-z0-9._/-]*[a-z0-9](?::[\w][\w.-]*)?(?:@sha256:[0-9a-f]{64})?$/;
// base64 후보 — YAML 블록 스칼라로 **줄바꿈**될 수 있어 조각을 이어 붙인 뒤 판정한다.
// ⚠️ 줄 길이 하한을 크게 잡으면 안 된다. 실측: barman manifest의 SIDECAR_IMAGE는 둘째 줄이
// `AuMTMuMA==`(10자)라 하한 16으로는 **첫 줄만** 이어 붙여 `…sidecar:v`로 잘린 채 디코드됐다 —
// 참조를 잡긴 하되 값이 틀리면 태그 일치 검사·원장 대조가 전부 어긋난다. 판정은 길이가 아니라
// **디코드 결과의 모양**(IMG_SHAPE)이 한다.
const B64_RUN = /(?:^[ \t]*[A-Za-z0-9+/=]{4,}[ \t]*$\n?)+/gm;

// `key`가 필요한 이유(확정 9/17): Renovate 도달성은 **경로만으로 결정되지 않는다**. kubernetes manager는
// 표준 `image:` 키만 추출하므로 CNPG Cluster CR의 `imageName:`은 같은 파일 안에 있어도 **추출되지 않는다**.
// 이건 추측이 아니라 이 레포가 이미 라이브에서 겪은 것이다 — 커밋 ba9bc2a(#373): "Renovate #362는 표준
// image: 키인 basebackup만 갱신하고 CNPG imageName:(cluster/restore-drill)을 누락해 digest 드리프트를 유발".
// 경로만 보면 그 참조가 **거짓으로 소유됨** 판정을 받아 stale-pin이 초록으로 통과한다.
type RefKey = "image" | "imageName" | "block" | "hidden";
type Ref = { file: string; ref: string; hidden: boolean; key: RefKey };

export function visibleRefs(path: string, text: string): Ref[] {
  const out: Ref[] = [];
  for (const m of text.matchAll(IMG_KEY)) {
    const v = m[2];
    if (v.includes("{{") || v.startsWith("$")) continue; // 템플릿·변수는 렌더 전이라 참조가 아니다
    out.push({ file: path, ref: v, hidden: false, key: m[1] === "imageName" ? "imageName" : "image" });
  }
  return out;
}

// Dockerfile의 `FROM` — base 이미지도 공급망이다(`ops/pg-tools/Dockerfile`이 유일한 실사용처).
// ⚠️ 멀티스테이지의 `FROM <stage>`(앞 스테이지 별칭)는 이미지가 아니다 — `/`나 `:`가 있어야 참조로 본다.
export function dockerfileRefs(path: string, text: string): Ref[] {
  if (!/(^|\/)Dockerfile$/.test(path)) return [];
  const out: Ref[] = [];
  for (const m of text.matchAll(/^FROM[ \t]+(?:--platform=\S+[ \t]+)?(\S+)/gm)) {
    const v = m[1];
    if (v.startsWith("$") || (!v.includes("/") && !v.includes(":"))) continue;
    out.push({ file: path, ref: v, hidden: false, key: "image" });
  }
  return out;
}

// apps 레인의 **블록 형태** 이미지(`image:` 아래 repo/tag/digest 하위키 — 공유 차트 스키마).
// ⚠️ 스칼라 추출기만 두면 이 형태가 통째로 안 잡힌다. 실측: 그 상태에서 `apps/*/deploy/prod/values.yaml`
// 분기가 **죽은 규칙**이었다(참조가 0건이라 그 분기를 타는 것이 하나도 없었다). 소유자 클래스가
// 비어 있으면 "소유자 있음"이 아니라 "안 보고 있음"이고, 둘은 같은 초록이다.
export function blockRefs(path: string, text: string): Ref[] {
  const m = /^image:\n((?:[ \t]+\S.*\n?)+)/m.exec(text);
  if (!m) return [];
  const repo = /^[ \t]+(?:repo|repository):[ \t]*["']?([^\s"'#]+)/m.exec(m[1])?.[1];
  if (!repo) return [];
  const tag = /^[ \t]+tag:[ \t]*["']?([^\s"'#]+)/m.exec(m[1])?.[1];
  const digest = /^[ \t]+digest:[ \t]*["']?(sha256:[0-9a-f]{64})/m.exec(m[1])?.[1];
  return [{ file: path, ref: `${repo}${tag ? `:${tag}` : ""}${digest ? `@${digest}` : ""}`, hidden: false, key: "block" }];
}

// base64 안에 숨은 이미지 참조. **이 클래스가 어떤 스캐너에도 안 걸린다는 것이 요점**이므로 별도로 본다.
// ⚠️ 한계를 명시한다: 여기서 잡는 것은 "디코드하면 이미지 모양인 base64 블록"뿐이다. gzip·암호화·
// 분할 인코딩은 못 본다. 그건 근사가 아니라 **원리적 미탐**이라 원장에 적어 두는 것 외에 방법이 없다.
export function hiddenRefs(path: string, text: string): Ref[] {
  const out: Ref[] = [];
  for (const m of text.matchAll(B64_RUN)) {
    const joined = m[0].replace(/[\s]/g, "");
    if (joined.length < 24) continue;
    let decoded: string;
    try {
      decoded = Buffer.from(joined, "base64").toString("utf8");
    } catch {
      continue;
    }
    const t = decoded.trim();
    // 디코드 결과가 **이미지 하나**여야 한다(임의 바이너리·설정 덩어리를 이미지로 오인하지 않는다).
    if (!t || t.includes("\n") || t.length > 300) continue;
    if (!t.includes("/") && !t.includes(":")) continue;
    if (!IMG_SHAPE.test(t)) continue;
    out.push({ file: path, ref: t, hidden: true, key: "hidden" });
  }
  return out;
}

// ── Renovate 도달성 ───────────────────────────────────────────────────────────
// 분류표만 보고 "Renovate 소유"로 통과시키면 안 된다(design-r2 R-5) — `ignorePaths` 변경이나 manager
// 패턴 공백이면 실제로는 추출 불가인데도 초록이 되어 **조용한 stale-pin 노출**이 된다. 그래서 설정에서
// 계산한다. Renovate를 실제로 돌리는 dry-run이 가장 정확하지만 CI 비용이 크므로 **fail-closed 근사**를
// 쓰고, 알려진 매치/논매치를 센티넬 테스트로 박아 근사 붕괴를 감지한다(그 테스트가 이 근사의 증인이다).
type Renovate = { include: RegExp[]; ignore: RegExp[] };

function globToRe(g: string): RegExp {
  // Renovate ignorePaths는 minimatch glob이다. 여기 쓰이는 형태(`**/x/**`, `a/b/**`)만 다룬다.
  const re = g
    .split("/")
    .map((seg) => (seg === "**" ? "(?:.*)" : seg.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, "[^/]*")))
    .join("/")
    .replace(/\(\?:\.\*\)\//g, "(?:.*/)?")
    .replace(/\/\(\?:\.\*\)$/, "(?:/.*)?");
  return new RegExp(`^${re}$`);
}

export function loadRenovate(root: string): Renovate {
  // **필수 읽기**다 — 부재 시 빈 목록으로 폴백하면 "Renovate가 아무것도 안 본다"가 되어 전 참조가
  // 무소유로 뒤집히거나(오탐 폭발) 반대로 통과한다. 어느 쪽이든 조용하면 안 된다.
  let cfg: Record<string, unknown>;
  try {
    cfg = JSON.parse(readFileSync(`${root}/${RENOVATE_PATH}`, "utf8")) as Record<string, unknown>;
  } catch (e) {
    // 부재/파손을 **구별 가능한 메시지로** 낸다. 조용히 빈 설정으로 폴백하면 도달성이 전부 false가 되어
    // 모든 참조가 '무소유'로 뒤집히는데, 그 red는 "설정을 못 읽었다"와 "정말 소유자가 없다"를 구별하지
    // 못한다 — 진단이 정반대로 간다(mutation이 이 자리를 죽은 검사로 지목했다).
    throw new Error(`${RENOVATE_PATH}을 읽을 수 없다(도달성 판정 불가): ${e instanceof Error ? e.message : String(e)}`);
  }
  const include: RegExp[] = [];
  const collect = (v: unknown) => {
    if (!Array.isArray(v)) return;
    for (const p of v) {
      const s = String(p);
      const m = /^\/(.*)\/$/.exec(s);
      if (m) include.push(new RegExp(m[1]));
    }
  };
  for (const key of ["kubernetes", "argocd", "helmv3", "dockerfile"]) {
    const mgr = cfg[key] as Record<string, unknown> | undefined;
    // ⚠️ `enabled: false`는 패턴을 지우는 것과 **의미가 같다**(그 manager가 아무것도 추출하지 않는다).
    // 모델하지 않으면 한 줄로 수십 건의 소유자가 유령이 된다 — 적대 검토가 실측: `"kubernetes":
    // {"enabled": false}`에서 가드가 26건을 여전히 `renovate` 소유로 보고하며 exit 0이었다.
    // (packageRules의 `enabled:false`는 **dep 단위** 스코프라 파일 단위 판정으로 표현할 수 없다 —
    //  그건 이 근사의 한계로 남기고 원장·주석에 적는다.)
    if (mgr?.enabled === false) continue;
    collect(mgr?.managerFilePatterns);
  }
  for (const cm of (cfg.customManagers as Record<string, unknown>[] | undefined) ?? []) {
    collect(cm.managerFilePatterns);
  }
  // ⚠️ **기본 manager도 모델한다.** `loadRenovate`가 명시 `managerFilePatterns`만 모으면, Renovate가
  // 자동 감지하는 파일(Dockerfile 등)이 "도달 불가"로 판정돼 **거짓 무소유**가 된다. 이 레포는
  // kubernetes/argocd처럼 자동 감지가 안 되는 것만 패턴을 명시하고, dockerfile은 config:recommended의
  // 기본값에 맡긴다. 명시적으로 끈 경우(enabled:false)는 위에서 이미 걸러진다.
  if ((cfg.dockerfile as Record<string, unknown> | undefined)?.enabled !== false) {
    include.push(/(^|\/)Dockerfile$/);
  }
  const ignore = ((cfg.ignorePaths as string[] | undefined) ?? []).map(globToRe);
  return { include, ignore };
}

export function renovateReaches(path: string, r: Renovate): boolean {
  if (r.ignore.some((re) => re.test(path))) return false;
  return r.include.some((re) => re.test(path));
}

// ── 원장 ──────────────────────────────────────────────────────────────────────
type Decl = { artifact?: unknown; why?: unknown; freshness?: unknown; since?: unknown; owner_action?: unknown };

// 원장 로딩·통일 shape·항목 구조는 readLedger 소유, 죽은-선언·무소유 매칭 대조는 audit 소유
// (CONTEXT.md 「정책 원장」). 필드가 왜 필수인지의 산문은 원장 _readme가 진다.
const LEDGER_SCHEMA = {
  type: "object",
  required: ["artifact", "why", "freshness", "since", "owner_action"],
  properties: {
    artifact: { type: "string", minLength: 1 },
    why: { type: "string", minLength: 1 },
    freshness: { type: "string", minLength: 1 },
    since: { type: "string", pattern: "^\\d{4}-\\d{2}-\\d{2}$" },
    owner_action: { type: "string", minLength: 1 },
  },
  additionalProperties: false,
};

function loadUnowned(root: string): Decl[] {
  return readLedger<Decl[]>({ path: POLICY_PATH, container: "unowned", entrySchema: LEDGER_SCHEMA, root });
}

// ── 소유자 판정 ───────────────────────────────────────────────────────────────
export type Owner = "repin-ops-image" | "bump-poll" | "renovate" | "none";

// ops 미러 이미지의 canonical 태그 — 소유자는 build→bump write-back(repin-ops-image)이다.
// tools/repin-ops-image.ts의 CATALOG와 같은 집합이어야 한다(둘 다 "이 이미지는 우리가 재핀한다"의 선언).
const REPINNED_OPS = [/pg-tools:18-rclone@sha256:/, /\/skopeo:alpine@sha256:/];

export function resolveOwner(r: Ref, renovate: Renovate, bespoke: Set<string>): Owner {
  if (REPINNED_OPS.some((re) => re.test(r.ref))) return "repin-ops-image";
  if (/^apps\/[^/]+\/deploy\/prod\/values\.yaml$/.test(r.file)) return "bump-poll";
  if (bespoke.has(r.file)) return "bump-poll";
  // 숨은 참조는 Renovate가 원리적으로 추출할 수 없다 — base64 안이라 어떤 manager도 파싱하지 못한다.
  if (r.hidden) return "none";
  // ⚠️ 경로가 매치돼도 **키가 추출 가능해야** 소유다(위 RefKey 주석 — #373이 라이브로 증명했다).
  if (r.key === "imageName") return "none";
  // ⚠️ 여기 `.sh` 전용 판정을 두지 않는다. mutation이 **죽은 규칙**임을 드러냈고(현재 manager 패턴이
  // 전부 `\.ya?ml$`로 끝나 `.sh`는 경로 매치 자체가 안 된다) 더 나쁘게는 **틀릴 수 있다** — 누군가
  // `.sh`를 잡는 customManager를 추가하면 그 참조는 정당하게 Renovate 소유가 되는데 그 판정이
  // 그걸 막아 버린다. 도달성은 설정에서 계산하는 것으로 충분하다.
  return renovateReaches(r.file, renovate) ? "renovate" : "none";
}

// `.image-pin.json` descriptor가 가리키는 파일(베스포크 레인 — bump-poll이 그 경로를 재핀한다).
export function bespokeFiles(root: string): Set<string> {
  const out = new Set<string>();
  // descriptor 자체는 `.json`이라 매니페스트 스코프에 없다 — git 열거로 찾는다.
  let listed = "";
  try {
    listed = execFileSync("git", ["ls-files", "--", "*/.image-pin.json"], { cwd: root, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
  } catch { /* git 없음 = 빈 집합. 아래 바닥값이 잡는다. */ }
  for (const d of listed.split("\n").filter(Boolean)) {
    try {
      const desc = JSON.parse(readFileSync(`${root}/${d}`, "utf8")) as { file?: string };
      if (typeof desc.file === "string") out.add(`${d.slice(0, d.lastIndexOf("/"))}/${desc.file}`);
    } catch { /* 깨진 descriptor는 소유 주장이 아니다 — 무소유로 남아 원장 선언을 요구한다 */ }
  }
  return out;
}

// ── CLI ───────────────────────────────────────────────────────────────────────

export function audit(root: string): { refs: Ref[]; bad: string[]; owners: Map<string, Owner> } {
  const bad: string[] = [];
  const renovate = loadRenovate(root);
  const bespoke = bespokeFiles(root);
  // 원장 결함은 열거 붕괴가 아니라 **위반**이다 — refs 도메인은 정상 평가되므로 마커를 유지한 채
  // FAIL 목록으로 보고한다(부재·파싱·항목 구조 판정은 readLedger, 근인 메시지가 목록 맨 앞).
  let unowned: Decl[] = [];
  try {
    unowned = loadUnowned(root);
  } catch (e) {
    bad.push(e instanceof Error ? e.message : String(e));
  }

  const refs: Ref[] = [];
  for (const e of walkManifests("image-ownership", root)) {
    refs.push(...visibleRefs(e.path, e.text), ...blockRefs(e.path, e.text), ...dockerfileRefs(e.path, e.text), ...hiddenRefs(e.path, e.text));
  }

  // I1 — 같은 `repo:tag`는 같은 digest여야 한다. 핀 게이트가 못 보는 축이다(D-1).
  const byTag = new Map<string, Set<string>>();
  for (const r of refs) {
    const m = /^(.+?):([^:@/]+)@(sha256:[0-9a-f]{64})$/.exec(r.ref);
    if (!m) continue;
    const key = `${m[1]}:${m[2]}`;
    (byTag.get(key) ?? byTag.set(key, new Set()).get(key)!).add(m[3]);
  }
  for (const [tag, digests] of byTag) {
    if (digests.size > 1) {
      bad.push(`태그 ${tag}가 digest ${digests.size}종으로 갈렸다: ${[...digests].join(" / ")} — 부분 갱신(skew)`);
    }
  }

  // 소유자 판정 + 무소유는 원장 선언 강제. (항목 필드 구조 검증은 readLedger가 이미 했다.)
  const declared = new Set(unowned.map((d) => String(d.artifact ?? "")));

  const owners = new Map<string, Owner>();
  const usedDecls = new Set<string>();
  for (const r of refs) {
    const owner = resolveOwner(r, renovate, bespoke);
    // ⚠️ 구분자는 **이스케이프**로 쓴다(`\u0000`) — 리터럴 NUL 바이트를 소스에 박으면 grep이 그 파일을
    //    **바이너리로 판정해 내용을 통째로 건너뛴다**. 그러면 이 레포의 grep 기반 가드 전부에게 이 파일이
    //    보이지 않게 되고, 그건 조용한 무측정이다(실측: 이 파일의 마커가 파생 로스터에서 누락됐다).
    owners.set(`${r.file}\u0000${r.ref}`, owner);
    if (owner !== "none") continue;
    // 무소유 — 원장에 파일 또는 `파일#참조`로 선언돼 있어야 한다.
    const keys = [`${r.file}#${r.ref}`, r.file];
    const hit = keys.find((k) => declared.has(k));
    if (hit) { usedDecls.add(hit); continue; }
    bad.push(
      `무소유 이미지 참조: ${r.file} — ${r.ref}${r.hidden ? " (base64 안에 숨음)" : ""}. ` +
        `${POLICY_PATH}에 '${r.file}#${r.ref}' 또는 '${r.file}'로 선언하라(freshness 채널과 owner_action 포함)`,
    );
  }
  // 죽은 선언 — 아무도 대조하지 않는 주장은 원장이 아니다. 단 차트-내부 클래스는 레포에 파일이 없으므로
  // `chart:` 접두로 표시하고 이 검사에서 제외한다(그건 아래 차트 선언 완전성이 대신 지킨다).
  for (const a of declared) {
    // `chart:`·`operator-injected:` 접두는 **레포에 문자열이 없는** 클래스다(차트 내부 기본 이미지,
    // operator가 런타임에 주입하는 이미지). 참조 스캔으로는 원리적으로 매치될 수 없으므로 죽은-선언
    // 검사에서 제외한다 — 이 면제가 없으면 정당한 선언이 red가 된다(적대 검토가 mutation으로 실증).
    if (a.startsWith("chart:") || a.startsWith("operator-injected:")) continue;
    if (!usedDecls.has(a)) bad.push(`${POLICY_PATH}: '${a}' 선언이 어떤 무소유 참조와도 매치되지 않는다(죽은 선언)`);
  }

  // D-2 — 차트 내부 기본 이미지. 레포에 **파일이 없으므로** 참조 스캔으로는 원리적으로 안 잡힌다.
  // 차트 선언(helmrelease.yaml · argocd Application `chart:` · CHART_VERSION)을 열거해 각각이
  // `chart:<이름>` 항목으로 선언됐는지 본다 — 새 차트를 들이면 선언을 강제한다.
  let charts: string[] = [];
  try {
    const files = execFileSync("git", ["ls-files", "--", "platform"], { cwd: root, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] })
      .split("\n").filter(Boolean);
    for (const f of files) {
      // ⚠️ 모양을 **파일명이 아니라 kind/스키마로** 판정한다. 경로 패턴으로 좁히면 실존하는 모양이
      // 조용히 빠진다 — 적대 검토 실측: `platform/argocd/root/newchart-app.yaml`(root-app이 recurse로
      // **실제 싱크한다**)와 `Chart.yaml`의 `dependencies:`가 둘 다 선언 강제를 빠져나갔고, 그 상태에서
      // 가드는 refs 38·rc=0으로 초록이었다(바닥값도 무력 — 참조 수가 안 변한다).
      // ⚠️ 기존 세 모양을 **교체하지 않고 추가**한다: helmrelease.yaml(HelmChartInflationGenerator)에서
      //    나오는 traefik·tailscale-operator·sealed-secrets 3종이 다른 모양 어디에도 없기 때문이다.
      if (/\/helmrelease\.yaml$/.test(f)) {
        const t = readFileSync(`${root}/${f}`, "utf8");
        const n = /^name:\s*(\S+)/m.exec(t);
        if (n) charts.push(n[1]);
      } else if (/^platform\/argocd\/CHART_VERSION$/.test(f)) {
        charts.push("argo-cd");
      } else if (/\.ya?ml$/.test(f)) {
        const t = readFileSync(`${root}/${f}`, "utf8");
        // ArgoCD Application의 인라인 helm chart — 경로 무관(root/apps 밖도 recurse로 싱크된다).
        if (/^kind:\s*Application\s*$/m.test(t) || /\nkind:\s*Application\s*\n/.test(t)) {
          for (const m of t.matchAll(/^\s*chart:\s*(\S+)/gm)) charts.push(m[1]);
        }
        // Helm 차트의 `dependencies:` — 서브차트도 자기 기본 이미지를 들여온다.
        if (/^apiVersion:\s*v[12]\s*$/m.test(t) && /^dependencies:/m.test(t)) {
          const dep = /^dependencies:\n([\s\S]*?)(?=^\S|\Z)/m.exec(t);
          if (dep) for (const m of dep[1].matchAll(/^\s*-\s*name:\s*(\S+)/gm)) charts.push(m[1]);
        }
      }
    }
  } catch { /* git 부재 — 아래 바닥값이 잡는다 */ }
  charts = [...new Set(charts)].sort();
  for (const c of charts) {
    if (!declared.has(`chart:${c}`)) {
      bad.push(
        `차트 '${c}'의 내부 기본 이미지에 digest 소유자 선언이 없다 — 차트는 untracked(charts/ gitignored) + ` +
          `renovate ignorePaths라 **원리적으로** 도달 불가다. ${POLICY_PATH}에 'chart:${c}'로 선언하라`,
      );
    }
    usedDecls.add(`chart:${c}`);
  }
  for (const a of declared) {
    if (a.startsWith("chart:") && !usedDecls.has(a)) {
      bad.push(`${POLICY_PATH}: '${a}' — 그런 차트 선언이 레포에 없다(차트 제거 후 원장 잔존)`);
    }
  }

  return { refs, bad, owners };
}

if (import.meta.main) {
  let flags;
  let floors: Map<string, number>;
  try {
    const taken = takeFloors(process.argv.slice(2));
    floors = taken.floors;
    flags = typedFlags(taken.rest, { value: ["--repo-root"], bool: ["--report"] });
  } catch (e) {
    console.error(e instanceof Error ? e.message : String(e));
    console.error("사용법: check-image-ownership.ts [--repo-root <path>] [--floor refs=<n>] [--report]");
    process.exit(2);
  }
  const root = flags.str("--repo-root", ".")!;

  // 실행 순서(열거 → floor → SCAN → 검사 → 종료코드)는 guardMain이 구조로 소유한다 —
  // 원장 로딩 실패(readLedger throw)와 renovate.json 읽기 실패는 열거 실패로 접혀 마커 없이 죽는다.
  let res!: ReturnType<typeof audit>;
  guardMain({
    floors,
    domains: [{
      scan: "check-image-ownership:refs",
      min: 20,
      floorHint: "이 회계가 vacuous해진다",
      enumerate: () => { res = audit(root); return res.refs.length; },
    }],
    output: "stdout",
    check: () => {
      if (flags.bool("--report")) {
        for (const [k, owner] of [...res.owners].sort()) {
          const [file, ref] = k.split("\u0000");
          console.log(`${owner.padEnd(14)} ${file} — ${ref}`);
        }
      }
      return res.bad;
    },
    report: (v) => {
      console.error("FAIL: 이미지 소유권 회계 위반:");
      for (const b of v) console.error(`  ${b}`);
    },
    ok: (counts) => console.log(`check-image-ownership OK (참조 ${counts[0]}건 전건 소유자 확정 또는 원장 선언)`),
  });
}
