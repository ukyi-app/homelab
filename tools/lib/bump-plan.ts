// bump 계획 계약 module — apps 레인/베스포크 레인 배포 핀 갱신의 plan 항목·명명·레인 인가를
// 소유한다(lib-convergence d3·08 · CONTEXT.md 「bump 계획」). 종전에는 이 계약이 세 프로세스에
// 독립 선언돼 있었다(poll-ghcr `type Plan` · run-bump-plan `type PlanItem` — optionality 상이 ·
// ensure-bump-pr `LANES` + 생산자 소스를 주석으로 붙여넣은 복붙-주석 seam). 생산자와 검증자가
// 같은 문자열을 각자 적으면 한쪽만 바뀔 때 소유 증명이 조용히 실패한다 — 여기가 그 유일 선언이다.
//
// plan 항목은 **런타임 디코드되는 판별 union**(design r1-1): 플래너는 noop·refuse도 적법하게
// 내므로 Lane("bump"|"propose-pr")은 Change에만 있다. plan은 JSON 경계를 건너므로 TS 타입만으로는
// 부족하다 — decodePlan()이 fail-closed로 검증하고, 미지 action·형식 위반은 조용한 skip이 아니라
// throw다. target은 판별 신원 {kind: "app"|"bespoke", name}(r1-2) — 두 레인은 인가 소스가 다르다
// (.bindings.json vs .image-pin.json).
//
// 신원은 프로세스 경계를 관통한다(design r2-1, 08): 브랜치가 kind를 인코딩하고
// (`bump-poll/<kind>/<name>-<tag>`), 인코딩(branchFor)과 역디코딩(parseBranch)을 이 module이
// **둘 다** 소유한다 — 형제 스윕·소유 증명이 브랜치명에서 target을 복원할 때 같은 module을
// 지나므로 인코딩·디코딩이 어긋날 자리가 없다. 구형 무한정 브랜치(`bump-poll/<name>-<tag>`)의
// 이행 판정도 여기다: app으로만 해석하되(legacy 표식), 동명 bespoke 표면이 실재하면 그 해석은
// 성립하지 않는다(legacyAmbiguity — fail-closed는 소비자 몫).
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { TAG_RE, descriptorAutoDeploy } from "./image-pin.ts";

// 레인의 런타임 값 목록도 여기가 SSOT다 — 소비자(ensure-bump-pr의 isLane)가 로컬 사본을 들면
// union이 늘 때 컴파일 red 없이 그 소비자만 조용히 거부한다(설계가 없애려던 한쪽-드리프트).
export const LANES = ["bump", "propose-pr"] as const;
export type Lane = (typeof LANES)[number];
export type TargetKind = "app" | "bespoke";
export type Target = { kind: TargetKind; name: string };

export type PinRef = { tag: string; digest: unknown };
export type Candidate = { gitsha: string; tag: string; digest: unknown };

type ItemBase = { target: Target; reason: string; src?: string; writePath?: string; pin?: string };
export type Change = ItemBase & { action: Lane; current: PinRef; candidate: Candidate; src: string; writePath: string };
export type Noop = ItemBase & { action: "noop"; current: PinRef | null };
export type Refusal = ItemBase & { action: "refuse"; current: PinRef | null };
export type PlanItem = Change | Noop | Refusal;

// ── 명명·신원 — 생산(run-bump-plan)과 소유 증명 검증(ensure-bump-pr)이 공유하는 문자열 ──────────
export const WRITER_NAME = "ukyi-homelab-writer[bot]";
export const WRITER_EMAIL = "293311924+ukyi-homelab-writer[bot]@users.noreply.github.com";

// 브랜치 네임스페이스 문법 — 열거(ensure-bump-pr의 reconcile/형제 스윕)가 이 접두로 대상을 거른다.
// NAME_RE는 **열거 관용**이다(mutator 게이트 APP_NAME_RE보다 느슨) — 네임스페이스에 실재하는 ref를
// 좁게 읽으면 과소 열거 = 해제 누락이 된다. 이름 정책의 강제는 mutator(bump-tag·run-bump-plan) 몫.
export const NS_PREFIX = "bump-poll/";
const NAME_RE = /^[a-z0-9-]+$/;

export function branchFor(target: Target, tag: string): string {
  return `${NS_PREFIX}${target.kind}/${target.name}-${tag}`;
}

export function commitMessage(target: Target, tag: string): string {
  // ⚠️ kind를 문구에 넣지 않는다 — 구형 브랜치(레거시)의 head 커밋도 이 문구로 만들어졌고,
  //    소유 증명(proveOurCommit)은 브랜치에서 복원한 target으로 이 함수를 재계산해 대조한다.
  return `chore: ${target.name} 이미지를 ${tag}(digest 핀)로 갱신 (GHCR 폴링)`;
}

// ── 브랜치 역디코딩 — branchFor의 정확한 역함수 + 레거시(구형 무한정 이름) 해석 ────────────────
// `<name>-<tag>` 분해는 모호하지 않다: TAG_RE는 `sha-` 뒤에 순수 hex만 허용하므로 `-sha-`가 여러 번
// 나와도 꼬리가 TAG_RE에 걸리는 분기점은 마지막 것 하나뿐이다(앞에서 자르면 꼬리에 `-`가 섞여 반드시
// 실패). 그래서 `x-sha-abc1234`처럼 이름이 tag 모양을 품어도 정확히 갈린다.
// 우리 문법이 아니면 null — 관용 해석은 금지다(잘못 읽으면 남의 ref를 우리 것으로 소유하게 된다).
export type ParsedBranch = { target: Target; tag: string; legacy: boolean };
const KINDS = new Set(["app", "bespoke"]);

function splitNameTag(rest: string): { name: string; tag: string } | null {
  const cut = rest.lastIndexOf("-sha-");
  if (cut <= 0) return null; // 이름이 없거나 `-sha-` 분기점이 없다
  const name = rest.slice(0, cut);
  const tag = rest.slice(cut + 1);
  if (!NAME_RE.test(name)) return null;
  if (!TAG_RE.test(tag)) return null; // 앵커 완전일치 — 아니면 이 브랜치는 우리 형식이 아니다
  return { name, tag };
}

export function parseBranch(branch: string): ParsedBranch | null {
  if (!branch.startsWith(NS_PREFIX)) return null;
  const rest = branch.slice(NS_PREFIX.length);
  const slash = rest.indexOf("/");
  if (slash > 0) {
    const kind = rest.slice(0, slash);
    if (!KINDS.has(kind)) return null; // 미지 세그먼트를 kind로 지어 읽지 않는다
    const nt = splitNameTag(rest.slice(slash + 1));
    if (nt === null) return null;
    return { target: { kind: kind as TargetKind, name: nt.name }, tag: nt.tag, legacy: false };
  }
  // 구형 무한정 이름 — kind가 없다. app으로만 해석한다(구 생산자는 apps 레인·베스포크 레인 모두
  // 이 형태를 냈지만, 해석을 갈라 줄 정보가 브랜치엔 없다). 그 해석이 성립하는지는 legacyAmbiguity가 가른다.
  const nt = splitNameTag(rest);
  if (nt === null) return null;
  return { target: { kind: "app", name: nt.name }, tag: nt.tag, legacy: true };
}

// 레거시 이행 판정 — 구형 브랜치의 app 해석은 **동명 bespoke 표면이 실재하면 거짓말**이 된다
// (그 브랜치는 베스포크 bump였을 수 있고, 어느 쪽 인가도 증명할 수 없다). 소비자는 이 사유로
// fail-closed한다(무장이 있으면 회수 + run red). null = 해석 유효(이행 소음 0).
export function legacyAmbiguity(root: string, name: string): string | null {
  const pin = surfaceFile(root, "bespoke", name);
  if (!existsSync(pin)) return null;
  return `구형 브랜치 이름에 kind가 없는데 동명 bespoke 표면이 실재한다(${pin}) — ` +
    "app 해석을 인가 근거로 쓸 수 없다(fail-closed). 열린 구형 PR을 닫고 다음 폴링 주기의 kind 인코딩 브랜치로 이행하라";
}

// ── 레인 인가 해소 — planApp/probeLane에 두 벌이던 autoDeploy 접기의 유일 구현 ─────────────────
// 플래너 계약: 파일 없음 = 파싱 불가 = autoDeploy:false = propose-pr(인가는 명시 true뿐).
// resolution이 어떻게 정해졌는지를 나른다 — absent는 정상(조용), unreadable은 사람이 고칠 일
// (시끄럽게), conflict는 동명 app/bespoke 충돌(r1-2의 사고 경로 — 어느 쪽 인가도 적용하지 않는다).
export type LaneResolution = "present" | "absent" | "unreadable" | "conflict";
export type LaneProbe = {
  target: Target | null; // conflict/absent면 null — 신원을 확정할 수 없다
  lane: Lane;
  resolution: LaneResolution;
  source: string | null;
  why: string | null;
};

function surfaceFile(root: string, kind: TargetKind, name: string): string {
  return kind === "app"
    ? path.join(root, "apps", name, "deploy", "prod", ".bindings.json")
    : path.join(root, "platform", name, "prod", ".image-pin.json");
}

// kind-지정 인가 해소 — 신원이 이미 확정된 target(kind 인코딩 브랜치·argv `--kind`)의 **자기 SSOT만**
// 읽는다. 반대 레인 표면의 실재는 판정 밖이다 — 동명 target은 브랜치도 인가 소스도 분리된다(08 e2e의
// 축). conflict는 kind 미확정 진입점(resolveLane)의 어휘라 여기서는 나오지 않는다.
export function laneFor(root: string, target: Target, known?: { parsed: unknown }): LaneProbe {
  const file = surfaceFile(root, target.kind, target.name);
  if (!existsSync(file)) {
    return {
      target, lane: "propose-pr", resolution: "absent", source: null,
      why: `autoDeploy SSOT 없음(${file}) — 플래너 계약상 autoDeploy:false(= propose-pr)`,
    };
  }
  let parsed: unknown;
  if (known !== undefined) {
    parsed = known.parsed;
  } else {
    try {
      parsed = JSON.parse(readFileSync(file, "utf8"));
    } catch (e) {
      return {
        target, lane: "propose-pr", resolution: "unreadable", source: file,
        why: `autoDeploy SSOT 파싱 실패(${file}): ${e instanceof Error ? e.message : String(e)} — autoDeploy:false로 접는다(fail-closed)`,
      };
    }
  }
  return {
    target,
    lane: descriptorAutoDeploy(parsed as { autoDeploy?: unknown }) ? "bump" : "propose-pr",
    resolution: "present",
    source: file,
    why: null,
  };
}

// kind 미확정 진입점(플래너의 이름 순회)용 — 이름 하나로 두 표면을 조사해 신원까지 해소한다.
// known — 콜사이트가 이미 읽어 둔 자기 레인의 SSOT(재읽기·재파싱 방지 + 파싱 실패 의미가
// 콜사이트 경로 하나로 유지된다). conflict 탐지(반대 레인 표면 실재)는 known과 무관하게 돈다.
// ⚠️ 두 인가 정책의 공존은 의도다(축은 진입점의 신원 확정 여부): 여기의 conflict refuse는 **신규
//    계획의 동결**이고("이름을 갈라라" — 동명 쌍에 새 bump/PR을 내지 않는다), 이미 선 인가(열린 PR의
//    무장)는 kind 인코딩 브랜치에서 복원한 target으로 laneFor가 **각자의 SSOT**로만 판정한다 —
//    동결이 기존 배포 인가까지 소급 박탈하지 않고, 분리가 신규 계획의 모호성을 되살리지도 않는다.
export function resolveLane(root: string, name: string, known?: { kind: TargetKind; parsed: unknown }): LaneProbe {
  const candidates: { kind: TargetKind; file: string }[] = [
    { kind: "app", file: surfaceFile(root, "app", name) },
    { kind: "bespoke", file: surfaceFile(root, "bespoke", name) },
  ];
  const present = candidates.filter((c) => existsSync(c.file));
  if (present.length === 2) {
    return {
      target: null, lane: "propose-pr", resolution: "conflict", source: null,
      why: `동명 target 충돌 — app(.bindings.json)과 bespoke(.image-pin.json)가 둘 다 실재한다(${present.map((c) => c.file).join(" | ")}). ` +
        `어느 쪽 autoDeploy도 적용하지 않는다(fail-closed) — 이름을 갈라라`,
    };
  }
  if (present.length === 0) {
    return {
      target: null, lane: "propose-pr", resolution: "absent", source: null,
      why: `autoDeploy SSOT 없음(${candidates.map((c) => c.file).join(" | ")}) — 플래너 계약상 autoDeploy:false(= propose-pr)`,
    };
  }
  const hit = present[0]!;
  const target: Target = { kind: hit.kind, name };
  return laneFor(root, target, known !== undefined && known.kind === hit.kind ? { parsed: known.parsed } : undefined);
}

// ── 와이어 인코딩/디코딩 — plan은 JSON으로 프로세스 경계를 건넌다 ────────────────────────────────
const ACTIONS = new Set(["noop", "refuse", "bump", "propose-pr"]);

export function encodePlan(items: PlanItem[]): string {
  return JSON.stringify(items, null, 2);
}

function fail(i: number, msg: string): never {
  throw new Error(`plan[${i}]: ${msg} — 미지·불량 항목은 조용한 skip이 아니라 red다(fail-closed)`);
}

export function decodePlan(raw: string): PlanItem[] {
  let j: unknown;
  try { j = JSON.parse(raw); } catch (e) { throw new Error(`plan JSON 파싱 실패: ${e instanceof Error ? e.message : String(e)}`); }
  if (!Array.isArray(j)) throw new Error("plan은 배열이어야 한다");
  return j.map((it: any, i): PlanItem => {
    if (!it || typeof it !== "object") fail(i, "항목이 객체가 아니다");
    if (!ACTIONS.has(it.action)) fail(i, `미지 action '${String(it.action)}'`);
    const t = it.target;
    if (!t || typeof t !== "object" || !KINDS.has(t.kind) || typeof t.name !== "string" || t.name === "") {
      fail(i, `target 신원 불량(kind∈{app,bespoke} + name 필수): ${JSON.stringify(t)}`);
    }
    if (typeof it.reason !== "string") fail(i, "reason 문자열 필수");
    // 구 와이어의 app 필드는 더 이상 싣지 않지만, 실려 왔다면 target의 파생이어야만 통과시킨다 —
    // 갈린 채 통과하면 app만 읽는 구 소비자와 target을 읽는 신 소비자가 **다른 대상**을 본다.
    if (it.app !== undefined && it.app !== t.name) fail(i, `app('${String(it.app)}')이 target.name('${t.name}')과 갈린다`);
    if (it.action === "bump" || it.action === "propose-pr") {
      if (!it.candidate || typeof it.candidate.gitsha !== "string" || typeof it.candidate.tag !== "string") {
        fail(i, "Lane 항목은 candidate{gitsha,tag}가 필요하다");
      }
      if (!it.current || typeof it.current.tag !== "string") fail(i, "Lane 항목은 current.tag가 필요하다");
      if (typeof it.writePath !== "string" || it.writePath === "") fail(i, "Lane 항목은 writePath가 필요하다");
      if (typeof it.src !== "string" || it.src === "") fail(i, "Lane 항목은 src가 필요하다");
      // kind↔pin 정합 — 러너는 pin 유무로 bump-tag 모드(apps 분리 키 vs 인라인 핀)를 가른다.
      // 갈린 채 통과하면 엉뚱한 레인의 파일을 편집하려 든다(경로 부재로 죽는 게 최선의 결과다).
      if (t.kind === "bespoke") {
        if (typeof it.pin !== "string" || it.pin === "") fail(i, "bespoke Lane 항목은 pin(디스크립터 경로)이 필요하다");
      } else if (it.pin !== undefined) {
        fail(i, `app Lane 항목에 pin(${String(it.pin)})이 실려 있다 — kind와 pin이 갈린다`);
      }
    }
    return it as PlanItem;
  });
}
