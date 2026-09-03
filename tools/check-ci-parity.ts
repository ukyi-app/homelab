// `make ci` ↔ ci.yaml job `gate` **패리티 회계**.
//
// 병: Makefile은 `ci` 타깃을 "ci.yaml job 'gate'를 로컬에서 그대로 재현"이라고 선언한다. 그런데 그 주장을
// 검증하던 것은 `test_make-ci-parity.bats`의 **하드코딩된 5개 토큰**(chart·ledger·audit·shellcheck·
// alertmanager-e2e)이 `make -n ci`에 있는지 보는 것뿐이었다. 즉 목록에 없는 게이트 스텝은 아무리 늘어나도
// 보이지 않는다 — 실측 시점에 gate의 run 스텝 19개 중 **8개**가 `make ci`에 없었는데 전 검사가 초록이었다.
// 하필 하드코딩된 5개가 전부 미러된 것들이라 "우연히" 통과한 것이다.
//
// 이건 이 레포가 반복해서 맞은 클래스다(티켓 07: 재핀 소비처 하드코딩 목록이 레포와 어긋남). 처방도 같다 —
// **목록을 손으로 적지 말고 원본에서 파생하고, 파생된 항목마다 소유자를 강제한다.**
//
// 이 도구가 하는 일:
//   ① gate의 `run` 스텝을 **ci.yaml에서 파생**한다(하드코딩 0). 스텝 수 바닥값으로 열거 붕괴를 막는다.
//   ② 모든 스텝은 원장(policy/ci-parity.json)에 **계상**돼야 한다. 미계상 = red → 새 게이트 스텝을 넣는
//      사람이 "이건 로컬에서 어떻게 도는가"를 반드시 답하게 된다.
//   ③ 죽은 선언(원장엔 있는데 ci.yaml엔 없는 스텝) = red. 아무도 대조하지 않는 주장은 원장이 아니다.
//   ④ `mirrored`는 선언한 로컬 커맨드가 **`make -n ci` 실제 출력에** 있어야 한다. 여기가 load-bearing이다 —
//      단, 대조 전에 출력을 정제한다. `make -n ci` 출력에는 **호출이 아닌 것**이 섞여 있다: 전제 프로브
//      `command -v <도구>`와, 도구 부재 시 이름만 남기는 미평가 라벨 append. 둘 다 그 도구를 부르지
//      않는데 문자열은 남는다 — 원문에 대조를 걸면 **실제 호출만 지워도 통과한다**(실측: `then actionlint;`를
//      `then :;`로 바꿔도 초록. 선언이 자기 자신을 증명한다).
//      Makefile에서 스텝이 빠지면 이 검사가 red를 낸다(Makefile 텍스트를 파싱하지 않는다. make 자신에게
//      해소를 맡긴다 — 조건부·변수·전제 타깃을 사람이 다시 구현하면 그 재구현이 곧 다음 드리프트다).
//   ⑤ `covered`는 로컬의 **다른 메커니즘**이 덮는 경우다. 그 메커니즘이 실재하는지(파일·문자열)를 검사한다.
//   ⑥ `excluded`는 로컬에서 안 도는 것이다. why·since·owner_action이 전부 있어야 한다 — 선언되지 않은
//      부재는 통과할 수 없고, 사유 없는 선언도 통과할 수 없다.
//
//   ⑦ `mirrored`의 `local` 배열이 **ci.yaml 스텝 본문의 커맨드 전건**을 담는지. ④는 원장 → Makefile
//      한 방향뿐이라, ci.yaml 스텝에 가드를 추가하고 원장에 안 적어도 아무도 red를 못 냈다 —
//      실측 2026-08-21: `실 도메인 가드` 스텝의 커맨드 10건 중 원장엔 **8건**만 있었고
//      `check-locale-collation`·`check-gh-secret-coverage`가 빠진 채 오래 초록이었다. 그 목록이
//      곧 AGENTS.md가 금지하는 **하드코딩 소비처 목록**이었다. ⇒ 목록을 ci.yaml에서 파생해 대조한다.
//      (④는 그대로 둔다: ⑦은 "원장이 스텝을 다 담았는가", ④는 "담긴 것이 make ci에서 실제로 도는가".)
//
//   ⑧ `mirrored`의 `local` 토큰이 **그 gate 스텝의 run 본문에도** 실재하는지. ④·⑦은 스텝을
//      **이름**으로만 계상한다 — 그래서 이름을 보존한 채 본문만 갈아치우면 ④는 Makefile 쪽
//      문자열로 통과하고, ⑦은 본문에 커맨드가 없어 **침묵**한다(방향 ⑦은 "보이는 커맨드가 원장에
//      있는가"만 본다). 실측 2026-09-03: 실 ci.yaml의 `run: bun run verify:ledger`를
//      `run: echo swapped`로 바꿔도 ci-parity·guard-authority·workflow-readiness가 전건 초록이었다
//      (겹은 bats 두 레인뿐 — 그것도 하드코딩된 네 토큰에 한정된다). ⑧이 그 자리를 문다.
//      표기가 **정당하게 다른** 스텝(gate는 `make chart-test`를 부르고 make ci는 그 타깃의 레시피를
//      편다)은 항목에 `gate_contains`로 본문 쪽 토큰을 명시한다. 그 필드는 `local`이 이미 본문에
//      있으면 **거부**되므로 손 관리 문자열이 두 벌로 번지지 않는다.
//      covered/excluded는 ⑧의 대상 밖이다 — covered는 "**다른** 로컬 수단이 덮는다"는 선언이라
//      gate 본문과 대조할 토큰 자체가 없고(covered_by는 덮는 쪽 파일이다), excluded는 local이 없다.
//
// ⚠️ 이 도구는 "gate와 make ci가 같다"를 증명하지 않는다. **모든 차이가 의도된 것인지**를 증명한다.
//    그 구분이 핵심이다 — 완전 일치를 강제하면 docker 없는 환경에서 make ci가 못 돌고, 결국 아무도 안 쓴다.

import { existsSync, readFileSync } from "node:fs";
import { sh as shExec } from "./lib/exec.ts";
import { guardMain, takeFloors } from "./lib/scan-floor.ts";
import { readLedger } from "./lib/policy-ledger.ts";

const ROOT = process.cwd();
// 바닥값 오버라이드는 공용 어휘 `--floor check-ci-parity=<n>`뿐이다(어휘 통일 d1).
let floors: Map<string, number>;
try {
  const taken = takeFloors(process.argv.slice(2));
  if (taken.rest.length) throw new Error(`알 수 없는 인자: ${taken.rest.join(" ")}`);
  floors = taken.floors;
} catch (e) {
  console.error(`${e instanceof Error ? e.message : String(e)}\n사용법: check-ci-parity.ts [--floor check-ci-parity=<n>]`);
  process.exit(2);
}
const CI = ".github/workflows/ci.yaml";
const LEDGER = "policy/ci-parity.json";
const GATE_JOB = "gate";

// gate가 이 아래로 줄면 열거가 붕괴한 것이다(yq 실패·job 리네임·스키마 변경). 그 상태에서 "미계상 0건"은
// 검사한 게 없다는 뜻이지 통과가 아니다.
// ⚠️ 스텝이 늘면 이 값도 함께 올린다 — 안 올리면 바닥이 조용히 느슨해진다.
//    여기에 **현재 건수를 적지 않는다**: 아무도 대조하지 않는 손 관리 수치는 반드시 드리프트한다
//    (이 줄에 '20스텝 / 바닥 18'이라 적혀 있었고 실측은 25/19였다). 현재값은 SCAN 마커를 읽어라.
//    **래칫이 아니다**: 스텝을 정당하게 줄이는 변경에서는 같이 내리면 된다. 목적은 "0에 가까운 붕괴"를
//    잡는 것이지 스텝 수를 고정하는 게 아니다.
// 열거 붕괴 바닥값 — **상수다. env 주입 경로를 열지 않는다**(argv 명시 오버라이드는 공용 어휘
// `--floor` 하나 — env와 달리 호출자가 모르게 꺼질 수 없다).
// ⚠️ 한때 테스트가 붕괴 경로를 관측하려고 `CI_PARITY_MIN_STEPS` env를 열었으나 되돌렸다:
//    이 가드는 required gate이고, `CI_PARITY_MIN_STEPS=0` 한 줄로 바닥값이 통째로 꺼졌다(실측).
//    붕괴 관측에는 주입이 필요 없다 — 이 도구는 `process.cwd()`를 읽으므로 픽스처 디렉토리에서
//    실행하면 열거가 자연히 0건이 된다(상수는 커널의 requireCount 안전망이 덮는다).
const MIN_STEPS = 19;

type Status = "mirrored" | "covered" | "excluded";
interface Entry {
  name: string;
  status: Status;
  local?: string | string[];
  // ⑧ 전용 — gate 스텝 본문 쪽 토큰. local의 표기가 본문과 정당하게 다를 때만 쓴다(아래 ⑧ 참조).
  gate_contains?: string;
  covered_by?: { file: string; contains: string };
  why?: string;
  since?: string;
  owner_action?: string;
}

const errors: string[] = [];
const fail = (m: string) => errors.push(m);

function sh(cmd: string, args: string[]): string {
  // seam 경유(d6③) — 실패는 throw(파생 실패를 guardMain이 열거 실패로 접는 계약). 64MiB 캡처 유지.
  // timeoutMs 0 = 종전 execFileSync 무-timeout 보존(make -n ci가 느린 머신에서 30s를 넘을 수 있다).
  const r = shExec(cmd, args, { cwd: ROOT, timeoutMs: 0, maxBuffer: 64 * 1024 * 1024 });
  // 문구에 argv 앞부분을 실어 **어느 파생**이 죽었는지 가른다(스텝 이름/본문 파생이 같은 yq -r 접두다).
  if (!r.ok) throw new Error(`${cmd} ${args.join(" ").slice(0, 160)} 실패: ${r.err || `exit ${r.status}`}`);
  return r.out;
}

// ── ① gate의 run 스텝을 ci.yaml에서 파생 ──────────────────────────────────────────────────────────
// yq로 뽑는다(YAML 파서 재구현 금지). 이름 없는 스텝은 원장 키가 없으므로 **즉시 red**다 — 익명 스텝을
// 허용하면 "무명 스텝은 계상 안 해도 된다"는 구멍이 생긴다.
// 파생 실패(yq 죽음·이름/본문 어긋남)는 throw — guardMain이 열거 실패로 접어 마커 없이 죽는다.
let stepNames: string[] = [];
let stepRuns: string[] = [];
const runByName = new Map<string, string>();
function deriveSteps(): number {
  const names = sh("yq", [
    "-r",
    `.jobs.${GATE_JOB}.steps[] | select(has("run")) | (.name // "((unnamed))")`,
    CI,
  ]);
  stepNames = names.split("\n").map((s) => s.trim()).filter(Boolean);
  // 스텝 본문(run 텍스트)도 함께 파생한다 — ⑦의 대조 원본이다. 이름과 같은 순서로 나온다.
  // 스텝 사이 구분자로 NUL을 쓸 수 없으므로 유일한 센티널을 쓴다(본문에 나올 수 없는 형태).
  const runs = sh("yq", [
    "-r",
    `.jobs.${GATE_JOB}.steps[] | select(has("run")) | .run + "\n@@STEP@@"`,
    CI,
  ]);
  stepRuns = runs.split("@@STEP@@").slice(0, -1);
  if (stepRuns.length !== stepNames.length) {
    throw new Error(
      `스텝 이름 ${stepNames.length}건 ≠ 스텝 본문 ${stepRuns.length}건 — 파생이 어긋났다. ` +
        `이 상태로 ⑦을 돌리면 엉뚱한 본문을 엉뚱한 이름에 붙여 대조한다.`,
    );
  }
  stepNames.forEach((n, i) => { if (stepRuns[i] !== undefined) runByName.set(n, stepRuns[i]); });
  return stepNames.length;
}

// run 본문에서 **실행되는 레포 커맨드**만 뽑는다. 주석 줄은 명령이 아니고, 글롭 인자
// (`git ls-files 'tests/gates/vmalert-*-firing-e2e.sh'`)는 경로가 아니라 패턴이라 제외한다.
// 원장 항목(basename 또는 글롭)이 스텝의 커맨드를 덮는가. **basename끼리** 비교한다 —
// 전체 경로 포함 검사는 원장의 정상 표기를 거짓 위반으로 만들고, 느슨한 substring은
// `sh` 같은 조각이 전부를 덮어 대조를 무의미하게 만든다.
// 원장 항목은 인터프리터 접두(`bash tests/…`)와 인자(`tools/…​.ts --ci`)를 함께 가질 수 있다.
// **스크립트 확장자를 가진 첫 토큰**이 경로다. 없으면 첫 토큰으로 떨어진다(`shellcheck`·`actionlint`).
function base(p: string): string {
  const toks = p.trim().split(/\s+/);
  const path = toks.find((t) => /\.(sh|ts|mts)$/.test(t)) ?? toks[0] ?? p;
  return path.split("/").pop() ?? path;
}
function ledgerCovers(want: string, cmd: string): boolean {
  const w = base(want);
  const c = base(cmd);
  if (w === c) return true;
  if (!w.includes("*")) return false;
  const re = new RegExp("^" + w.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*") + "$");
  return re.test(c);
}

function commandsIn(run: string): string[] {
  const out = new Set<string>();
  for (const raw of run.split("\n")) {
    const line = raw.replace(/#.*$/, "");
    if (!line.trim()) continue;
    // ⚠️ 후행 lookahead에 `;` `&` `|` `)` `}`가 **반드시** 들어간다 — 예전엔 `(?=\s|$|"|')`뿐이라
    //    `bash scripts/x.sh; then`·`bash scripts/x.sh|| exit 1`·`(bash scripts/x.sh)` 같은 정상 셸 표기가
    //    통째로 안 보였다. 방향 ⑦은 "보이는 커맨드가 원장에 있는가"만 보므로, 안 보이는 커맨드는
    //    대조 대상이 아니라 **침묵**한다 — 로스터가 파생 대조라는 보증이 그 표기에 대해 거짓이 된다.
    //    (도입 시점 실측으로는 ci.yaml 34건이 전부 잡혀 놓친 것은 0건이었다. 잠복을 닫는 수정이다.)
    const re = /(?:^|[\s;&|(])(?:bash|bun|sh|\.\/)?\s*((?:scripts|tools|tests)\/[A-Za-z0-9._/-]+\.(?:sh|ts|mts))(?=[\s;&|()}"']|$)/g;
    let m: RegExpExecArray | null;
    while ((m = re.exec(line)) !== null) {
      if (m[1].includes("*")) continue;
      out.add(m[1]);
    }
  }
  return [...out];
}

// `make -n ci` 출력에서 **실제 호출이 아닌 텍스트**를 지운다(④ 대조 전용).
//   · `command -v <도구>` — 전제 프로브다. 도구의 존재를 묻지, 도구를 부르지 않는다.
//   · `echo "…" >> <파일>` — 미평가 원장에 이름만 남기는 append다. 부르지 못했다는 기록이지 호출이 아니다.
// 변수명(`CI_UNEVAL`)에 기대지 않는다 — 그 이름이 바뀌면 정제가 조용히 멎고 fail-open이 돌아온다.
// recipe의 append-echo는 구조상 게이트 호출일 수 없으므로 형태로 지운다.
// 실측 2026-08-28: 실 레포 mirrored 22항목·local 34문자열에 대해 정제로 사라지는 것 **0건**(오탐 없음).
function execOnly(s: string): string {
  return s
    .replace(/command -v \S+/g, "")
    .replace(/\becho\s+"[^"]*"\s*>>[^\n;]*/g, "")
    .replace(/\becho\s+'[^']*'\s*>>[^\n;]*/g, "");
}

// ── 원장 + 대조(guardMain check 단계) ──────────────────────────────────────────────────────────
// 로딩·통일 shape({_readme, steps})·항목 구조는 readLedger(policy-ledger) 소유. 미계상·죽은 선언·
// ④~⑦ 대조 의미론과 상태별 조건부 요건은 이 콜사이트 소유다(CONTEXT.md 「정책 원장」).
const ENTRY_SCHEMA = {
  type: "object",
  required: ["name", "status"],
  properties: {
    name: { type: "string", minLength: 1 },
    status: { enum: ["mirrored", "covered", "excluded"] },
    local: {}, gate_contains: {}, covered_by: {}, why: {}, since: {}, owner_action: {},
  },
  additionalProperties: false,
};

const byName = new Map<string, Entry>();
function reconcile(): string[] {
  for (const n of stepNames.filter((n) => n === "((unnamed))")) {
    void n;
    fail(`gate에 이름 없는 run 스텝이 있다 — 원장은 이름으로 계상하므로 무명 스텝은 회계에서 빠진다. name을 붙여라.`);
  }
  const dupes = stepNames.filter((n, i) => stepNames.indexOf(n) !== i);
  if (dupes.length) fail(`gate 스텝 이름 중복: ${[...new Set(dupes)].join(", ")} — 원장 키가 모호해진다.`);

  // 원장 로딩 실패(부재·파싱·shape·항목 구조)는 **여기서** 잡아 ::error:: 채널로 낸다 — 문구·채널은
  // 콜사이트 소유이고, steps 도메인 자체는 이미 평가됐으므로 마커는 정당하다(readLedger 소유 경계).
  let entries: Entry[] = [];
  try {
    entries = readLedger<Entry[]>({ path: LEDGER, container: "steps", entrySchema: ENTRY_SCHEMA });
  } catch (e) {
    fail(e instanceof Error ? e.message : String(e));
    return errors; // 원장이 없으면 ②~⑦ 대조가 전부 무의미하다 — 홍수 대신 근인 하나로 보고한다.
  }
  for (const e of entries) {
    if (byName.has(e.name)) fail(`${LEDGER}: 중복 항목 '${e.name}'`);
    byName.set(e.name, e);
  }

  // ── ② 미계상 ──────────────────────────────────────────────────────────────────────────────────
  for (const n of stepNames) {
    if (n === "((unnamed))") continue;
    if (!byName.has(n)) {
      fail(
        `게이트 스텝이 원장에 없다: "${n}"\n` +
          `    → ${LEDGER}에 계상하라. mirrored(make ci가 같은 걸 돈다) / covered(다른 로컬 수단이 덮는다) /\n` +
          `      excluded(로컬에선 안 돈다 — why·since·owner_action 필수) 중 하나를 골라야 한다.`,
      );
    }
  }

  // ── ③ 죽은 선언 ───────────────────────────────────────────────────────────────────────────────
  for (const e of byName.values()) {
    if (!stepNames.includes(e.name)) {
      fail(`원장에만 있고 gate에는 없는 스텝: "${e.name}" — 스텝이 삭제·리네임됐다. 원장에서 지우거나 이름을 맞춰라.`);
    }
  }

  // ── ④ mirrored: make -n ci 실측 대조 ──────────────────────────────────────────────────────────
  let makeOut = "";
  let makeExec = "";
  const needMake = [...byName.values()].some((e) => e.status === "mirrored");
  if (needMake) {
    try {
      makeOut = sh("make", ["-n", "ci"]);
    } catch (e) {
      // ⚠️ 여기서 조용히 넘어가면 mirrored 전건이 무검사로 통과한다(fail-open). 명시적으로 죽인다.
      fail(`\`make -n ci\` 실행 실패 — mirrored 항목을 하나도 검증할 수 없다: ${(e as Error).message}`);
    }
    if (makeOut.trim().length === 0) fail("`make -n ci` 출력이 비었다 — mirrored 검증이 무측정이 된다.");
    makeExec = execOnly(makeOut);
  }

  // ── 프로덕션 호출은 floor-free다 ──────────────────────────────────────────────────────────────
  // --floor는 테스트·픽스처 전용 오버라이드다. env 주입 폐지 결정("한 줄로 required gate의 바닥값이
  // 꺼졌다")의 승계가 "argv라 호출자에게 보인다"는 주장인데, 그 주장을 사람 눈에만 맡기면 되돌림
  // 한 줄이 조용히 통과한다 — 이 회계가 기계로 진다(gate 스텝 본문 + make -n ci 실측 양쪽).
  for (const [n, run] of runByName) {
    if (run.includes("--floor")) {
      fail(`"${n}": gate 스텝이 --floor를 넘긴다 — 프로덕션 호출은 floor-free여야 한다(바닥값은 콜사이트 상수).`);
    }
  }
  if (makeOut.includes("--floor")) {
    fail("`make -n ci` 출력에 --floor가 있다 — 프로덕션 호출은 floor-free여야 한다(바닥값은 콜사이트 상수).");
  }

  for (const e of byName.values()) {
    // `gate_contains`는 mirrored 전용이다 — 다른 status에 달면 아무도 대조하지 않는 문자열이
    // 조용히 원장에 쌓인다(③ "죽은 선언"과 같은 클래스).
    if (e.gate_contains !== undefined) {
      if (e.status !== "mirrored") {
        fail(`"${e.name}": gate_contains는 mirrored 전용이다(현재 '${e.status}') — covered/excluded는 gate 본문과 대조할 로컬 토큰이 없다.`);
      } else if (typeof e.gate_contains !== "string" || e.gate_contains.length === 0) {
        fail(`"${e.name}": gate_contains가 빈 문자열이다 — 빈 needle은 모든 본문에 있다(대조가 항진식이 된다).`);
      }
    }
    switch (e.status) {
      case "mirrored": {
        // local은 문자열 하나 또는 **배열**이다. 배열이 필요한 이유: 게이트 스텝 하나가 여러 스위트를
        // 덮을 수 있다(예: bats ∥ 발화 e2e 동시 실행). 그때 문자열 하나만 대조하면 나머지가 make ci에서
        // 빠져도 통과한다 — 부분 대조는 대조가 아니다. **전건**이 있어야 한다.
        const wants = Array.isArray(e.local) ? e.local : e.local ? [e.local] : [];
        if (wants.length === 0) { fail(`"${e.name}": mirrored인데 local(대조할 커맨드 문자열)이 없다.`); break; }
        for (const w of wants) {
          if (typeof w !== "string" || w.length === 0) { fail(`"${e.name}": local 항목이 빈 문자열이다.`); continue; }
          if (makeOut && !makeExec.includes(w)) {
            fail(
              `"${e.name}": mirrored로 선언됐지만 \`make -n ci\` 출력에 '${w}'이(가) 없다.\n` +
                `    → make ci에서 빠졌거나 커맨드가 바뀌었다. Makefile을 고치거나 원장 상태를 바꿔라.\n` +
                `      (전제 프로브 \`command -v\`와 미평가 라벨은 호출이 아니라 대조에서 제외된다.)`,
            );
          }
        }
        // ⑦ 역방향: ci.yaml 스텝 본문의 커맨드가 전부 local에 있는가.
        // ⚠️ ④(원장 → make)만으로는 **원장에 안 적은 커맨드**가 원리적으로 안 보인다. 그 목록이
        //    손 관리 로스터가 되는 자리이고, 실제로 10건 중 2건이 빠진 채 오래 초록이었다.
        // ⚠️ 원장의 `local`은 **basename**이나 **글롭**이다(그 문자열은 `make -n ci` 출력 대조용이라
        //    Makefile이 쓰는 형태를 따른다 — 예: `vmalert-*-firing-e2e.sh`는 Makefile이 글롭을 쓰기
        //    때문이다). 전체 경로로만 대조하면 이 방향이 **정상 원장을 물어** 아무도 안 켠다.
        const body = runByName.get(e.name) ?? "";
        const inStep = commandsIn(body);
        for (const c of inStep) {
          if (!wants.some((w) => typeof w === "string" && ledgerCovers(w, c))) {
            fail(
              `"${e.name}": ci.yaml 스텝이 '${c}'를 부르는데 원장 local에 없다.\n` +
                `    → local은 스텝 본문의 커맨드를 **전건** 담아야 한다. 부분 대조는 대조가 아니다.`,
            );
          }
        }
        // ⑧ 이름 보존 + 본문 교체 — ④(원장→make)도 ⑦(본문→원장)도 못 보는 자리다.
        // ⑦이 못 보는 이유가 요점이다: 본문에 레포 커맨드가 없으면 대조할 것이 0건이라 **침묵**한다.
        // 여기서는 반대로 **원장이 선언한 토큰이 본문에 실재하는지**를 묻는다.
        if (e.gate_contains !== undefined) {
          // 표기가 정당하게 다른 자리(gate = make 타깃 · make ci = 그 타깃의 레시피)만 이 필드를
          // 쓴다. local이 이미 본문에 있는데도 선언하면 **손 관리 문자열이 두 벌**이 되므로 거부한다 —
          // 그 거부가 이 필드를 원장 전역으로 번지지 않게 하는 기계 장치다(선언 가능 ≠ 선언 허용).
          if (typeof e.gate_contains === "string" && e.gate_contains.length > 0) {
            if (wants.every((w) => typeof w === "string" && body.includes(w))) {
              fail(
                `"${e.name}": gate_contains가 불필요하다 — local 토큰이 이미 스텝 본문에 있다.\n` +
                  `    → 같은 토큰 하나가 양쪽에 실재하면 그것으로 족하다. 손 관리 문자열을 두 벌 만들지 마라.`,
              );
            } else if (!body.includes(e.gate_contains)) {
              fail(
                `"${e.name}": gate 스텝 본문에 gate_contains '${e.gate_contains}'가 없다 — 이름만 남고 본문이 갈렸다.`,
              );
            }
          }
        } else {
          for (const w of wants) {
            if (typeof w !== "string" || w.length === 0) continue; // 위에서 이미 보고했다
            if (!body.includes(w)) {
              fail(
                `"${e.name}": gate 스텝 본문에 local '${w}'이(가) 없다 — 이름을 보존한 채 run 본문이 갈렸다.\n` +
                  `    → 본문을 되돌리거나, 표기가 정당하게 다르면(gate가 make 타깃을 부르는 경우 등)\n` +
                  `      그 항목에 gate_contains로 본문 쪽 토큰을 명시하라.`,
              );
            }
          }
        }
        break;
      }
      case "covered": {
        if (!e.why) fail(`"${e.name}": covered인데 why가 없다 — 무엇이 덮는지 적어야 한다.`);
        const c = e.covered_by;
        if (!c?.file || !c?.contains) {
          fail(`"${e.name}": covered인데 covered_by.file/contains가 없다 — 덮는 메커니즘이 실재하는지 검사할 수 없다.`);
          break;
        }
        if (!existsSync(c.file)) { fail(`"${e.name}": covered_by.file '${c.file}' 부재.`); break; }
        if (!readFileSync(c.file, "utf8").includes(c.contains)) {
          fail(`"${e.name}": covered_by.file '${c.file}'에 '${c.contains}'가 없다 — 덮는다는 주장이 더 이상 참이 아니다.`);
        }
        break;
      }
      case "excluded": {
        for (const k of ["why", "since", "owner_action"] as const) {
          if (!e[k]) fail(`"${e.name}": excluded인데 ${k}가 없다 — 선언되지 않은 부재는 통과할 수 없다.`);
        }
        break;
      }
      default:
        fail(`"${e.name}": 알 수 없는 status '${e.status}' (mirrored|covered|excluded)`);
    }
  }
  return errors;
}

// 실행 순서(열거 → floor → SCAN → 검사 → 종료코드)는 guardMain이 구조로 소유한다.
// 종전에도 scanFloor가 바닥값·마커를 한 몸으로 냈다 — 커널 편입이 옮긴 것은 마커의 존재가
// 아니라 **순서의 소유**다(콜사이트가 floor·방출·검사의 순서를 손으로 맞추던 자리 소멸).
guardMain({
  floors,
  domains: [{
    scan: "check-ci-parity",
    min: MIN_STEPS,
    floorHint: 'job 리네임·yq 실패·스키마 변경 — 이 상태의 "미계상 0건"은 통과가 아니라 무측정이다',
    enumerate: deriveSteps,
  }],
  output: "stdout",
  check: reconcile,
  report: (v) => {
    for (const e of v) console.error(`::error::ci-parity: ${e}`);
    console.error(`\nci-parity: ${v.length}건 실패 (gate run 스텝 ${stepNames.length}건)`);
  },
  ok: () => {
    const n = (s: Status) => [...byName.values()].filter((e) => e.status === s).length;
    console.log(
      `ci-parity OK — gate run 스텝 ${stepNames.length}건 전건 계상: ` +
        `mirrored ${n("mirrored")} · covered ${n("covered")} · excluded ${n("excluded")}`,
    );
  },
});
