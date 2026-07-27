// G1 — 가드가 **권위 있는 실행 경로**를 갖는지 계산한다.
//
// 병: 가드가 추가되고, scripts/README.md에 등재되고, 전 게이트가 초록이고, **CI에서 한 번도 실행되지
// 않을 수 있다**. required check는 `gate` 하나(infra/github/repo.tf)인데 `make verify`는 CI에서 안 돈다 —
// Makefile의 스텝 목록과 ci.yaml의 스텝 목록은 서로 다른 손으로 쓴 목록이고 둘을 대조하는 것이 없었다.
// 특히 ci.yaml이 직접 부르는 `tests/gates/*.sh` 8개는 `*test_*.bats`가 아니라 check-bats-accounting의
// 도메인 밖이었다 — 9번째가 추가되고 잊혀도, 기존 하나가 삭제되고 파일만 남아도 감지되지 않았다.
//
// **계산하되 선언하지 않는다.** `policy/`에 소유권 레지스트리를 만들지 않는다 — 그건 이 회계가 고치려는
// 병("주장을 적어두고 아무도 대조하지 않는 것")을 하나 더 만드는 것이다. 멤버십을 **실제로 결정하는
// 것**에게 묻는다:
//   · `.github/workflows/ci.yaml`   → jobs.gate.steps[].run (+ `uses: ./.github/actions/X` 전개)
//   · `.github/workflows/*.yaml`    → `on.schedule`가 있는 워크플로의 steps[].run
//   · `./scripts/run-bats.sh --list` → gate가 **실제로 수집하는** bats 전량(하드코딩 목록 아님)
//   · `make -n <target>`             → Makefile 텍스트 파싱이 아니라 **make에게** 해소를 맡긴다
//   · `package.json` scripts         → `bun run verify:ledger` 같은 별칭을 전이적으로 해소
//
// **판정은 `authoritative >= 1`이다. `== 1`이 아니다.** venue는 의도적으로 겹친다 — check-skeleton은
// ci.yaml과 make verify 양쪽에서 돈다. 정확히-하나 모델이면 그게 이중소유 오탐이 된다.
//
// ⚠️ **이 회계가 아직 못 하는 것 — 호출이 가드의 실제 도메인에 닿는지는 판정하지 않는다.**
// 티켓은 "픽스처 전용·스모크 전용·skip-only 호출은 권위가 아니다"라고 했는데, 그 셋을 텍스트로
// 가르려다 실측으로 접었다. 두 반례가 모델을 무너뜨린다:
//   · `tests/test_alert_rules.bats:116`은 `--repo-root "${BATS_TEST_DIRNAME}/.."`로 **실 레포**를 가리킨다.
//     "인자가 있으면 픽스처" 규칙이면 check-alert-rules가 고아로 **오탐**된다.
//   · `tools/tests/test_app-deploy.bats:45`는 `run bash "$CHECK"`(무인자)로 실 트리를 검사하는데,
//     같은 파일의 다른 20여 곳은 픽스처다. 파일 단위로는 두 성격이 섞여 있다.
// 즉 fixture↔real 구분은 인자 형태로 결정되지 않는다(루트 인자가 실 레포를 가리킬 수 있다).
// 그래서 **과다 계상 쪽으로 기운다** — 있는 호출을 권위로 세되, 없는 호출을 지어내지는 않는다.
// 오탐(정당한 가드를 고아라 부름)보다 미탐이 낫다는 판단이다: 이 게이트의 첫 번째 의무는
// 거짓 경보로 신뢰를 잃지 않는 것이다. 정밀화는 후속(티켓 08의 스캔 건수 신호와 함께 하는 편이 낫다 —
// 가드가 "몇 건 검사했다"를 이미 출력하므로 실행 관측으로 fixture↔real을 가를 수 있다).
// skip-only(01의 `SKIP:` 마커)는 지금 판정에 영향이 없다: 유일한 해당 가드 verify-runbook-index가
// owner-local `make verify-runbook-index`로 이미 권위를 갖는다.
//
// 종료코드: tools/lib/cli.ts 규약(0=통과 · 1=권위 0인 가드 존재 · 2=사용법).
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { parse } from "yaml";
import { typedFlags } from "./lib/cli.ts";
import { walkManifests } from "./lib/repo-walk.ts";

const WORKFLOW_DIR = ".github/workflows";
const CI_WORKFLOW = `${WORKFLOW_DIR}/ci.yaml`;
const GATE_JOB = "gate";

// 로컬 mirror — **권위가 아니다**. 둘 다 "ci.yaml gate를 로컬에서 재현"이 목적이라 CI에서 돌지 않는다.
// 이걸 권위로 세면 "make verify에만 있고 CI엔 없는 가드"라는 정확히 그 병이 통과한다.
const MIRROR_TARGETS = new Set(["verify", "ci"]);

// 명령 세그먼트의 '실행 대상'을 찾을 때 건너뛰는 실행 동사·래퍼.
const EXEC_VERBS = new Set([
  "run", "bash", "sh", "bun", "node", "exec", "sudo", "env", "timeout", "xargs", "command", "time",
]);

type Venue = { id: string; kind: "gate" | "schedule" | "owner-local" | "mirror"; text: string };

// ── 명령줄 해석 ───────────────────────────────────────────────────────────────
// "이 텍스트가 가드를 **실행**하는가"를 묻는다. 단순 문자열 포함으로는 안 된다 — 주석의 언급과
// grep 패턴이 권위로 둔갑한다. 반대로 너무 엄격해도 안 된다: 실측된 형태가
// `CHECK="$ROOT/scripts/check-app-deploy.sh"` … `run bash "$CHECK"` 처럼 **변수 간접**을 쓴다
// (tools/tests/test_app-deploy.bats:7,45 — 직접 경로만 보면 이 가드가 고아로 오탐된다).
function commandHeads(line: string): string[] {
  const heads: string[] = [];
  for (const seg of line.split(/\|\||&&|[;|&()]/)) {
    const toks = seg.trim().split(/\s+/).filter(Boolean);
    for (let i = 0; i < toks.length; i++) {
      const t = toks[i].replace(/^["']+|["']+$/g, "");
      if (t === "") continue;
      if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(t)) continue; // 앞머리 env 할당(FOO=bar cmd)
      if (EXEC_VERBS.has(t)) continue;
      if (t.startsWith("-")) continue; // 래퍼 플래그
      heads.push(t);
      break;
    }
  }
  return heads;
}

function stripComment(line: string, hash: boolean): string {
  return hash ? line.replace(/^\s*#.*$/, "") : line.replace(/^\s*\/\/.*$/, "");
}

// 한 텍스트에서 변수 → 가드경로 바인딩을 수집한다(`CHECK="$ROOT/scripts/check-x.sh"`).
function bindings(text: string, guardPaths: string[]): Map<string, string> {
  const out = new Map<string, string>();
  for (const raw of text.split("\n")) {
    const line = stripComment(raw, true);
    const m = /^\s*(?:local\s+|export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.+)$/.exec(line);
    if (!m) continue;
    const hit = guardPaths.find((g) => m[2].includes(g));
    if (hit) out.set(m[1], hit);
  }
  return out;
}

function headRefs(head: string, guard: string, bound: Map<string, string>): boolean {
  const clean = head.replace(/["']/g, "");
  if (clean.endsWith(guard)) return true;
  const v = /^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$/.exec(clean);
  return v ? bound.get(v[1]) === guard : false;
}

// 텍스트가 가드를 실행하는가.
export function invokesGuard(text: string, guard: string, allGuards: string[]): boolean {
  const bound = bindings(text, allGuards);
  for (const raw of text.split("\n")) {
    const line = stripComment(raw, true);
    if (!line.trim()) continue;
    for (const head of commandHeads(line)) {
      if (headRefs(head, guard, bound)) return true;
    }
  }
  return false;
}

// ── venue 수집 ────────────────────────────────────────────────────────────────
function sh(cmd: string, args: string[], root: string): string {
  try {
    return execFileSync(cmd, args, { cwd: root, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
  } catch {
    return "";
  }
}

type Step = { run?: string; uses?: string };

function stepTexts(steps: Step[] | undefined, root: string): string {
  if (!Array.isArray(steps)) return "";
  const parts: string[] = [];
  for (const s of steps) {
    if (typeof s?.run === "string") parts.push(s.run);
    // 로컬 composite action은 gate 스텝의 연장이다 — 전개하지 않으면 그 안의 가드 호출이 사라진다.
    if (typeof s?.uses === "string" && s.uses.startsWith("./")) {
      for (const ext of ["action.yml", "action.yaml"]) {
        const p = `${root}/${s.uses.slice(2)}/${ext}`;
        if (!existsSync(p)) continue;
        try {
          const doc = parse(readFileSync(p, "utf8")) as { runs?: { steps?: Step[] } };
          parts.push(stepTexts(doc?.runs?.steps, root));
        } catch { /* 파싱 실패는 아래 venue 바닥값이 잡는다 */ }
        break;
      }
    }
  }
  return parts.join("\n");
}

// make 도움말에 선언된 타깃을 make 자신에게 물어 해소한다(Makefile 텍스트 파싱 금지 — 티켓 조항).
function makeTargets(root: string): string[] {
  const mk = existsSync(`${root}/Makefile`) ? readFileSync(`${root}/Makefile`, "utf8") : "";
  const names = new Set<string>();
  for (const line of mk.split("\n")) {
    const m = /^([a-zA-Z][a-zA-Z0-9_-]*):.*?##/.exec(line);
    if (m) names.add(m[1]);
  }
  return [...names].sort();
}

export function collectVenues(root: string): Venue[] {
  const venues: Venue[] = [];

  // ① ci.yaml의 gate job — 유일한 required check.
  const ciPath = `${root}/${CI_WORKFLOW}`;
  if (existsSync(ciPath)) {
    const ci = parse(readFileSync(ciPath, "utf8")) as { jobs?: Record<string, { steps?: Step[] }> };
    const gate = ci?.jobs?.[GATE_JOB];
    if (gate) venues.push({ id: `${CI_WORKFLOW}:${GATE_JOB}`, kind: "gate", text: stepTexts(gate.steps, root) });
  }

  // ② gate가 **실제로 수집하는** bats — 각 파일 전체가 호출면이다.
  //    하드코딩 목록이 아니라 러너에게 묻는다(수집 규칙이 바뀌면 이 회계도 따라간다).
  for (const f of sh("./scripts/run-bats.sh", ["--list"], root).split("\n").filter(Boolean)) {
    if (!existsSync(`${root}/${f}`)) continue;
    venues.push({ id: `gate-bats:${f}`, kind: "gate", text: readFileSync(`${root}/${f}`, "utf8") });
  }

  // ③ 스케줄 워크플로 직접 호출 — 크론 reconciler는 권위다(예: credential-expiry.yaml).
  for (const f of sh("git", ["ls-files", "--", `${WORKFLOW_DIR}/*.yaml`], root).split("\n").filter(Boolean)) {
    if (f === CI_WORKFLOW) continue;
    let doc: { on?: unknown; jobs?: Record<string, { steps?: Step[] }> };
    try { doc = parse(readFileSync(`${root}/${f}`, "utf8")); } catch { continue; }
    const on = doc?.on as Record<string, unknown> | undefined;
    if (!on || typeof on !== "object" || !("schedule" in on)) continue;
    const text = Object.values(doc.jobs ?? {}).map((j) => stepTexts(j?.steps, root)).join("\n");
    venues.push({ id: `schedule:${f}`, kind: "schedule", text });
  }

  // ④ make 타깃 — owner-local 전용 엔트리포인트(도메인이 CI에 없는 가드에겐 이것이 유일한 권위).
  //    `make verify`·`make ci`는 로컬 mirror라 비권위로 분리해 기록한다(디버깅용 — 판정엔 안 센다).
  for (const t of makeTargets(root)) {
    const text = sh("make", ["-n", t], root);
    if (!text) continue;
    venues.push({ id: `make:${t}`, kind: MIRROR_TARGETS.has(t) ? "mirror" : "owner-local", text });
  }

  // ⑤ 별칭 전이 해소 — `bun run verify:ledger` → package.json → scripts/verify-ledger.sh.
  //    해소하지 않으면 정당한 가드가 "도달 경로 0"으로 오탐된다.
  const pkgPath = `${root}/package.json`;
  if (existsSync(pkgPath)) {
    let scripts: Record<string, string> = {};
    try { scripts = (JSON.parse(readFileSync(pkgPath, "utf8")).scripts ?? {}) as Record<string, string>; } catch { /* noop */ }
    for (const v of venues) {
      const extra: string[] = [];
      for (const [name, body] of Object.entries(scripts)) {
        if (new RegExp(`bun run ${name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}(\\s|$)`).test(v.text)) extra.push(body);
      }
      if (extra.length) v.text += "\n" + extra.join("\n");
    }
  }

  return venues;
}

// ── CLI ───────────────────────────────────────────────────────────────────────
function fail(msg: string): never { console.error(`FAIL: ${msg}`); process.exit(1); }

if (import.meta.main) {
  let flags;
  try {
    flags = typedFlags(process.argv.slice(2), { value: ["--repo-root", "--min-scan"], bool: ["--json"] });
  } catch (e) {
    console.error(e instanceof Error ? e.message : String(e));
    console.error("사용법: check-guard-authority.ts [--repo-root <path>] [--min-scan <n>] [--json]");
    process.exit(2);
  }
  const root = flags.str("--repo-root", ".")!;
  // 열거 붕괴 바닥값 — 소비자 소유(repo-walk는 scan-floor를 갖지 않는다). 현재 가드 23개.
  const minScan = Number(flags.str("--min-scan", "15"));

  const guards = walkManifests("guards", root).map((e) => e.path);
  if (guards.length < minScan) {
    fail(`가드 열거 ${guards.length}건 < ${minScan} — 열거 붕괴(이 회계가 vacuous해진다)`);
  }

  const venues = collectVenues(root);
  const authoritativeVenues = venues.filter((v) => v.kind !== "mirror");
  if (authoritativeVenues.length === 0) fail("권위 venue 0건 — venue 수집 붕괴(ci.yaml/run-bats/make 확인)");

  const report = guards.map((g) => {
    const hits = venues.filter((v) => invokesGuard(v.text, g, guards));
    return {
      guard: g,
      authoritative: hits.filter((v) => v.kind !== "mirror").map((v) => v.id),
      nonAuthoritative: hits.filter((v) => v.kind === "mirror").map((v) => v.id),
    };
  });

  // --json이면 stdout은 **JSON만** — 사람용 요약을 섞으면 파이프 소비자가 파싱에 실패한다.
  const asJson = flags.bool("--json");
  if (asJson) console.log(JSON.stringify({ guards: guards.length, venues: venues.length, report }, null, 2));

  const orphans = report.filter((r) => r.authoritative.length === 0);
  if (orphans.length) {
    console.error("FAIL: 권위 있는 실행 경로가 0인 가드 — 삭제되거나 조용히 죽어도 아무도 모른다:");
    for (const o of orphans) {
      const mirror = o.nonAuthoritative.length ? ` (비권위 경로만: ${o.nonAuthoritative.join(", ")})` : " (어떤 경로에도 없음)";
      console.error(`  ${o.guard}${mirror}`);
    }
    console.error("  권위 = ci.yaml gate 스텝 · gate 수집 bats · 스케줄 워크플로 · owner-local make 타깃");
    process.exit(1);
  }
  if (!asJson) console.log(`check-guard-authority OK (가드 ${guards.length}건, venue ${venues.length}건, 전건 권위 경로 ≥1)`);
}
