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
//      Makefile에서 스텝이 빠지면 이 검사가 red를 낸다(Makefile 텍스트를 파싱하지 않는다. make 자신에게
//      해소를 맡긴다 — 조건부·변수·전제 타깃을 사람이 다시 구현하면 그 재구현이 곧 다음 드리프트다).
//   ⑤ `covered`는 로컬의 **다른 메커니즘**이 덮는 경우다. 그 메커니즘이 실재하는지(파일·문자열)를 검사한다.
//   ⑥ `excluded`는 로컬에서 안 도는 것이다. why·since·owner_action이 전부 있어야 한다 — 선언되지 않은
//      부재는 통과할 수 없고, 사유 없는 선언도 통과할 수 없다.
//
// ⚠️ 이 도구는 "gate와 make ci가 같다"를 증명하지 않는다. **모든 차이가 의도된 것인지**를 증명한다.
//    그 구분이 핵심이다 — 완전 일치를 강제하면 docker 없는 환경에서 make ci가 못 돌고, 결국 아무도 안 쓴다.

import { existsSync, readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";

const ROOT = process.cwd();
const CI = ".github/workflows/ci.yaml";
const LEDGER = "policy/ci-parity.json";
const GATE_JOB = "gate";

// gate가 이 아래로 줄면 열거가 붕괴한 것이다(yq 실패·job 리네임·스키마 변경). 그 상태에서 "미계상 0건"은
// 검사한 게 없다는 뜻이지 통과가 아니다.
// ⚠️ 스텝이 늘면 이 값도 함께 올린다 — 안 올리면 바닥이 조용히 느슨해진다(현재 20스텝 / 바닥 18).
//    **래칫이 아니다**: 스텝을 정당하게 줄이는 변경에서는 같이 내리면 된다. 목적은 "0에 가까운 붕괴"를
//    잡는 것이지 스텝 수를 고정하는 게 아니다.
const MIN_STEPS = 19;

type Status = "mirrored" | "covered" | "excluded";
interface Entry {
  name: string;
  status: Status;
  local?: string | string[];
  covered_by?: { file: string; contains: string };
  why?: string;
  since?: string;
  owner_action?: string;
}

const errors: string[] = [];
const fail = (m: string) => errors.push(m);

function sh(cmd: string, args: string[]): string {
  return execFileSync(cmd, args, { cwd: ROOT, encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
}

// ── ① gate의 run 스텝을 ci.yaml에서 파생 ──────────────────────────────────────────────────────────
// yq로 뽑는다(YAML 파서 재구현 금지). 이름 없는 스텝은 원장 키가 없으므로 **즉시 red**다 — 익명 스텝을
// 허용하면 "무명 스텝은 계상 안 해도 된다"는 구멍이 생긴다.
let stepNames: string[] = [];
try {
  const out = sh("yq", [
    "-r",
    `.jobs.${GATE_JOB}.steps[] | select(has("run")) | (.name // "((unnamed))")`,
    CI,
  ]);
  stepNames = out.split("\n").map((s) => s.trim()).filter(Boolean);
} catch (e) {
  fail(`ci.yaml에서 ${GATE_JOB} 스텝을 읽지 못했다(yq 실패): ${(e as Error).message}`);
}

if (stepNames.length < MIN_STEPS) {
  fail(
    `gate의 run 스텝 ${stepNames.length}건 < 바닥값 ${MIN_STEPS} — 열거 붕괴다(job 리네임·yq 실패·스키마 변경). ` +
      `이 상태의 "미계상 0건"은 통과가 아니라 무측정이다.`,
  );
}
for (const n of stepNames.filter((n) => n === "((unnamed))")) {
  void n;
  fail(`gate에 이름 없는 run 스텝이 있다 — 원장은 이름으로 계상하므로 무명 스텝은 회계에서 빠진다. name을 붙여라.`);
}
const dupes = stepNames.filter((n, i) => stepNames.indexOf(n) !== i);
if (dupes.length) fail(`gate 스텝 이름 중복: ${[...new Set(dupes)].join(", ")} — 원장 키가 모호해진다.`);

// ── 원장 ────────────────────────────────────────────────────────────────────────────────────────
let entries: Entry[] = [];
if (!existsSync(LEDGER)) {
  fail(`${LEDGER} 부재 — 패리티 원장이 없으면 이 검사는 아무것도 강제하지 않는다.`);
} else {
  try {
    const parsed = JSON.parse(readFileSync(LEDGER, "utf8"));
    entries = parsed.steps ?? [];
  } catch (e) {
    fail(`${LEDGER} 파싱 실패: ${(e as Error).message}`);
  }
}

const byName = new Map<string, Entry>();
for (const e of entries) {
  if (!e?.name) { fail(`${LEDGER}: name 없는 항목이 있다.`); continue; }
  if (byName.has(e.name)) fail(`${LEDGER}: 중복 항목 '${e.name}'`);
  byName.set(e.name, e);
}

// ── ② 미계상 ────────────────────────────────────────────────────────────────────────────────────
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

// ── ③ 죽은 선언 ─────────────────────────────────────────────────────────────────────────────────
for (const e of byName.values()) {
  if (!stepNames.includes(e.name)) {
    fail(`원장에만 있고 gate에는 없는 스텝: "${e.name}" — 스텝이 삭제·리네임됐다. 원장에서 지우거나 이름을 맞춰라.`);
  }
}

// ── ④ mirrored: make -n ci 실측 대조 ────────────────────────────────────────────────────────────
let makeOut = "";
const needMake = [...byName.values()].some((e) => e.status === "mirrored");
if (needMake) {
  try {
    makeOut = sh("make", ["-n", "ci"]);
  } catch (e) {
    // ⚠️ 여기서 조용히 넘어가면 mirrored 전건이 무검사로 통과한다(fail-open). 명시적으로 죽인다.
    fail(`\`make -n ci\` 실행 실패 — mirrored 항목을 하나도 검증할 수 없다: ${(e as Error).message}`);
  }
  if (makeOut.trim().length === 0) fail("`make -n ci` 출력이 비었다 — mirrored 검증이 무측정이 된다.");
}

for (const e of byName.values()) {
  switch (e.status) {
    case "mirrored": {
      // local은 문자열 하나 또는 **배열**이다. 배열이 필요한 이유: 게이트 스텝 하나가 여러 스위트를
      // 덮을 수 있다(예: bats ∥ 발화 e2e 동시 실행). 그때 문자열 하나만 대조하면 나머지가 make ci에서
      // 빠져도 통과한다 — 부분 대조는 대조가 아니다. **전건**이 있어야 한다.
      const wants = Array.isArray(e.local) ? e.local : e.local ? [e.local] : [];
      if (wants.length === 0) { fail(`"${e.name}": mirrored인데 local(대조할 커맨드 문자열)이 없다.`); break; }
      for (const w of wants) {
        if (typeof w !== "string" || w.length === 0) { fail(`"${e.name}": local 항목이 빈 문자열이다.`); continue; }
        if (makeOut && !makeOut.includes(w)) {
          fail(
            `"${e.name}": mirrored로 선언됐지만 \`make -n ci\` 출력에 '${w}'이(가) 없다.\n` +
              `    → make ci에서 빠졌거나 커맨드가 바뀌었다. Makefile을 고치거나 원장 상태를 바꿔라.`,
          );
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

// ── 보고 ────────────────────────────────────────────────────────────────────────────────────────
if (errors.length) {
  for (const e of errors) console.error(`::error::ci-parity: ${e}`);
  console.error(`\nci-parity: ${errors.length}건 실패 (gate run 스텝 ${stepNames.length}건)`);
  process.exit(1);
}
const n = (s: Status) => [...byName.values()].filter((e) => e.status === s).length;
console.log(
  `ci-parity OK — gate run 스텝 ${stepNames.length}건 전건 계상: ` +
    `mirrored ${n("mirrored")} · covered ${n("covered")} · excluded ${n("excluded")}`,
);
