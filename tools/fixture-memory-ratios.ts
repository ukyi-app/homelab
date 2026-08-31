// 발화 e2e 픽스처(VictoriaMetrics import 포맷 — 줄당 하나의 JSON 시계열)에서 한 컨테이너의
// **메모리 비율 세 축**을
// 읽어 내고, 그 픽스처가 커널 물리로 성립하는지 검증한다. vmalert-memory-nearlimit-firing-e2e.sh의
// preflight 오라클 — 그 하네스가 "픽스처가 두 판정을 실제로 가른다"를 단언하는 근거를 여기서 만든다.
//
// 왜 TS인가: CONTRIBUTING 「새 코드 배치 규칙」이 구조 데이터 파싱·계산을 tools/*.ts에 배정하고
// 셸 heredoc의 제3 언어 내장을 금지한다(typecheck 사각). 이 오라클은 정확히 그 버킷이다 —
// JSON 순회 + 산술 + 불변식 검증이고, load-bearing인데 인라인 python일 때는 테스트가 0건이었다.
//
// ⚠️ **판정은 여기서 하지 않는다.** 임계 비교(비율 > T)는 하네스가 자기 awk로 한다. 그 경계는
// ADR-0005(발화 e2e 하네스의 판정·레그·룰 계약을 공용 lib으로 올리지 않는다)를 지키는 자리다 —
// 기각된 셋의 논거가 "그 축이 하네스마다 다르다"인데, 임계 산술이 정확히 그렇다. 반면 커널 항등식은
// 하네스마다 갈릴 이유가 원리적으로 없어서 여기 있어도 그 논거에 걸리지 않는다.
//
// 출력: `<working_set> <usage−cache> <usage−inactive−active>` (limit 대비 비율, 소수 6자리, 공백 구분)
//   축이 셋인 이유는 하네스 헤더가 논증한다 — 가운데(usage−cache)는 배포 룰이 더는 쓰지 않지만
//   shmem 형상이 **그 판에서 침묵한다**는 것이 F1 회귀 앵커의 전제라 기계가 확인해야 한다.
//
// ⚠️ 이 파일은 VM 쓰기 엔드포인트 경로를 **리터럴로 적지 않는다**. check-alert-rules.ts의 push 메트릭
//    완전성 가드가 `tools/` 표면에서 그 리터럴을 보면 이 파일을 '메트릭 생산자'로 판정하고, 페이로드
//    정적 해석에 실패해 fail-closed FAIL을 낸다(실측). 이 도구는 픽스처를 **읽기만** 하므로 생산자
//    레지스트리 등재는 거짓 등재가 된다 — 그래서 가드를 끄는 대신 리터럴을 피한다.
//    (형제 생성기 vmalert-memory-nearlimit-gen.py는 tests/ 아래라 그 표면 밖이다.)
//
// 종료코드(tools/lib/cli.ts 규약): 0=성공 · 1=픽스처 검증 실패 · 2=사용법/플래그 오류

import { parseFlags } from "./lib/cli.ts";

const NEED = [
  "container_memory_working_set_bytes",
  "container_memory_usage_bytes",
  "container_memory_cache",
  "container_memory_total_inactive_file_bytes",
  "container_memory_total_active_file_bytes",
  "kube_pod_container_resource_limits",
] as const;

function fail(msg: string): never {
  console.error(`FAIL: ${msg}`);
  process.exit(1);
}

let flags: Record<string, string | boolean>;
try {
  flags = parseFlags(process.argv.slice(2), {
    value: ["--fixture", "--container"],
    bool: [],
  });
} catch (e) {
  console.error(`사용법: fixture-memory-ratios.ts --fixture <jsonl> --container <라벨>\n  ${(e as Error).message}`);
  process.exit(2);
}

const fixture = flags["--fixture"];
const container = flags["--container"];
if (typeof fixture !== "string" || typeof container !== "string") {
  console.error("사용법: fixture-memory-ratios.ts --fixture <jsonl> --container <라벨>");
  process.exit(2);
}

let text: string;
try {
  text = await Bun.file(fixture).text();
} catch {
  fail(`픽스처를 읽을 수 없다: ${fixture}`);
}

// 첫 샘플만 본다 — 이 계열 픽스처는 상수 시계열이다(gen이 values를 같은 값으로 채운다).
const v = new Map<string, number>();
for (const line of text.split("\n")) {
  if (!line.trim()) continue;
  let o: { metric?: Record<string, string>; values?: number[] };
  try {
    o = JSON.parse(line);
  } catch {
    fail(`픽스처에 JSON이 아닌 줄이 있다: ${line.slice(0, 80)}`);
  }
  const m = o.metric;
  if (!m || m.container !== container) continue;
  const name = m.__name__;
  const first = o.values?.[0];
  if (typeof name !== "string" || typeof first !== "number") continue;
  v.set(name, first);
}

const missing = NEED.filter((n) => !v.has(n));
if (missing.length > 0) fail(`픽스처에 ${container}의 메트릭 누락: ${missing.join(",")}`);

const ws = v.get(NEED[0])!;
const usage = v.get(NEED[1])!;
const cache = v.get(NEED[2])!;
const inactive = v.get(NEED[3])!;
const active = v.get(NEED[4])!;
const limit = v.get(NEED[5])!;

// ── 물리 정합성 — 이것이 깨진 픽스처는 커널이 만들 수 없는 상태이고, 그 위의 판정은 무의미하다 ──
if (!(limit > 0)) fail(`픽스처 ${container}: limit이 0 이하다(${limit})`);
if (ws > usage) fail(`픽스처 ${container}: working_set(${ws}) > usage(${usage})`);
if (cache > usage) fail(`픽스처 ${container}: cache(${cache}) > usage(${usage})`);
// 커널 항등식 — working_set은 독립 상수가 아니라 usage에서 inactive_file을 뺀 값이다.
if (ws !== usage - inactive) {
  fail(`픽스처 ${container}: working_set(${ws}) != usage−inactive_file(${usage - inactive})`);
}
// cgroup v2의 file은 inactive_file + active_file + shmem이라 두 축의 합보다 작을 수 없다.
if (cache < inactive + active) {
  fail(`픽스처 ${container}: cache(${cache}) < inactive+active(${inactive + active}) — 항등식 위반`);
}

const out = [
  ws / limit,
  (usage - cache) / limit,
  (usage - inactive - active) / limit,
];
console.log(out.map((n) => n.toFixed(6)).join(" "));
