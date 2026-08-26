// bump 계획 계약 module — apps 레인/베스포크 레인 배포 핀 갱신의 plan 항목·명명·레인 인가를
// 소유한다(lib-convergence d3 · CONTEXT.md 「bump 계획」). 종전에는 이 계약이 세 프로세스에
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
// ⚠️ 와이어 호환(08 전까지): encodePlan은 구 소비자(run-bump-plan·bump-poll.yaml)가 읽는
//    `app`(이름) 필드를 target과 **함께** 싣는다. 소비자가 decodePlan으로 이관(티켓 08)하면 정리한다.
// ⚠️ branchFor는 아직 kind를 인코딩하지 않는다 — 브랜치 문법 변경은 역디코딩(parseBranch)·형제
//    스윕·레거시 이행과 한 몸이라(design r2-1) 티켓 08에서 함께 간다. 여기서는 오늘의 문자열을
//    SSOT로 소유하는 것까지다.
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { descriptorAutoDeploy } from "./image-pin.ts";

export type Lane = "bump" | "propose-pr";
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

export function branchFor(target: Target, tag: string): string {
  return `bump-poll/${target.name}-${tag}`;
}

export function commitMessage(target: Target, tag: string): string {
  return `chore: ${target.name} 이미지를 ${tag}(digest 핀)로 갱신 (GHCR 폴링)`;
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

// known — 콜사이트가 이미 읽어 둔 자기 레인의 SSOT(재읽기·재파싱 방지 + 파싱 실패 의미가
// 콜사이트 경로 하나로 유지된다). conflict 탐지(반대 레인 표면 실재)는 known과 무관하게 돈다.
export function resolveLane(root: string, name: string, known?: { kind: TargetKind; parsed: unknown }): LaneProbe {
  const candidates: { kind: TargetKind; file: string }[] = [
    { kind: "app", file: path.join(root, "apps", name, "deploy", "prod", ".bindings.json") },
    { kind: "bespoke", file: path.join(root, "platform", name, "prod", ".image-pin.json") },
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
  let parsed: unknown;
  if (known && known.kind === hit.kind) {
    parsed = known.parsed;
  } else {
    try {
      parsed = JSON.parse(readFileSync(hit.file, "utf8"));
    } catch (e) {
      return {
        target, lane: "propose-pr", resolution: "unreadable", source: hit.file,
        why: `autoDeploy SSOT 파싱 실패(${hit.file}): ${e instanceof Error ? e.message : String(e)} — autoDeploy:false로 접는다(fail-closed)`,
      };
    }
  }
  return {
    target,
    lane: descriptorAutoDeploy(parsed as { autoDeploy?: unknown }) ? "bump" : "propose-pr",
    resolution: "present",
    source: hit.file,
    why: null,
  };
}

// ── 와이어 인코딩/디코딩 — plan은 JSON으로 프로세스 경계를 건넌다 ────────────────────────────────
const ACTIONS = new Set(["noop", "refuse", "bump", "propose-pr"]);
const KINDS = new Set(["app", "bespoke"]);

export function encodePlan(items: PlanItem[]): string {
  // app은 언제나 target에서 **파생**한다(스프레드 뒤에 두어 항목의 stray app이 이기지 못하게) —
  // 와이어의 app과 target.name이 갈리면 r1-2가 닫은 신원 분열이 와이어에서 부활한다.
  return JSON.stringify(items.map((it) => ({ ...it, app: it.target.name })), null, 2);
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
    // 와이어 호환 필드 app은 target의 파생이어야 한다 — 갈린 채 통과하면 app만 읽는 구 소비자와
    // target을 읽는 신 소비자가 **다른 대상**을 본다(신원 분열의 와이어 잔존).
    if (it.app !== undefined && it.app !== t.name) fail(i, `app('${String(it.app)}')이 target.name('${t.name}')과 갈린다`);
    if (it.action === "bump" || it.action === "propose-pr") {
      if (!it.candidate || typeof it.candidate.gitsha !== "string" || typeof it.candidate.tag !== "string") {
        fail(i, "Lane 항목은 candidate{gitsha,tag}가 필요하다");
      }
      if (!it.current || typeof it.current.tag !== "string") fail(i, "Lane 항목은 current.tag가 필요하다");
      if (typeof it.writePath !== "string" || it.writePath === "") fail(i, "Lane 항목은 writePath가 필요하다");
      if (typeof it.src !== "string" || it.src === "") fail(i, "Lane 항목은 src가 필요하다");
    }
    return it as PlanItem;
  });
}
