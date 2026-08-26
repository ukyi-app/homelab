// 열거 붕괴 → vacuous green 차단 커널 — **TypeScript adapter**.
// 셸 adapter는 `scripts/lib/scan-floor.sh`다. 둘은 같은 규약의 두 adapter이고, 마커 형태는
// 한 글자도 다르지 않다(함수 이름만 camelCase). 사람이 두 출력을 나란히 읽을 수 있어야 하고,
// 게이트의 파싱 정규식도 하나다.
//
// 병(TS 고유): 셸 콜사이트는 `[ "$got" -lt "$min" ]`이 수가 아닌 값에 **에러를 낸다**. TypeScript는
// `Number("abc")`가 NaN이고 `n < NaN`이 항상 false라 **바닥값이 통째로 꺼진 채 초록**이 된다.
// 실측(2026-08-25): `DISK_CAP_MIN_FLAGS=abc` → SCAN 방출 + rc=0. 오타 하나가 이 커널이 없애려는
// 실패 클래스를 그대로 되살렸다. 그래서 이 adapter에는 셸에 없는 세 번째 함수가 있다.
//
//   scanFloor(label, got, min, opts?)   건수 바닥값. 미만이면 진단 + 종료. 통과하면 SCAN 신호를 낸다.
//   scanSignal(label, n, opts?)         `SCAN: <라벨>: <n>` 마커만 낸다(바닥값 없는 카운트 자리용).
//   parseFloor(raw, source)             raw 문자열 → 바닥값 수. 아니면 진단 + exit 2.
//
// ⚠️ **바닥값을 통과한 실행만 신호를 낸다.** 실패 경로는 이미 stderr로 시끄럽고, 그때의 건수는
//    "검사했다"가 아니라 "붕괴했다"는 뜻이라 같은 마커로 내면 소비자가 정반대로 읽는다.
//    셸에서는 커널이 바닥값 시점에 내므로 자동으로 이 순서인데, 이 규약을 주석으로만 두었더니
//    TS 콜사이트 7곳 중 4곳이 어긋났다(실측 — 그것이 이 파일이 생긴 이유다).
//
// ⚠️ **이 커널은 종료하지 않는다. `ScanError`를 던지고 콜사이트가 종료를 소유한다.**
//    `tools/lib/`의 커널 규율이다 — `tools/README.md`("콜사이트가 정책 소유") · `image-pin.ts`
//    ("process.exit는 전부 콜사이트 소유") · `repo-walk.ts` · `sealed-contract.ts`가 같은 경계를 적었고,
//    `cli.ts`의 파싱 실패도 같은 형태다(throw → 콜사이트가 exit 2). 셸 adapter가 진단을 내고
//    `|| exit N`으로 콜사이트가 코드를 정하는 것과 같은 분업이며, 종료 **기전**만 언어를 따른다.
//    에러가 권고 코드를 실어 보내므로(`exitCode`) 콜사이트는 두 실패를 구별할 수 있고,
//    셸이 `exit 1`/`exit 2`로 갈리듯 자기 값으로 덮어쓸 수도 있다.
//
// ⚠️ **억제(quiet)는 출력 채널의 성질이지 판정의 성질이 아니다.** 마커만 삼키고 바닥값 검사와
//    stderr 진단은 그대로 수행한다. `check-guard-authority --json`이 stdout을 기계 판독 JSON으로
//    쓰기 때문에 필요하다 — 그 모드에서도 바닥값은 봐야 한다.
//
// ⚠️ `SKIP:`(exit 4 · 도메인이 정당하게 없어 평가하지 않음)과 **배타 채널**이다. 한 실행이 둘을
//    같이 내면 소비자가 모순된 사실을 받는다. 이 커널은 그 마커를 **방출하지 않는다** — 위 설명문은
//    주석이고, check-skip-signalling의 짝 검사는 주석 줄을 대상 밖에 둔다(그 가드가 근거를 적어 뒀다:
//    "규약을 설명하는 산문이 곳곳에 있다"). 방출하지 않는다는 것이 규약이지, 단어를 적지 않는 것이
//    규약은 아니다.
//
// ── 셸에서 이식하지 않은 두 함수 ──────────────────────────────────────────────
// `scan_enumerate` — 프로세스 치환이 열거자 rc를 삼키는 병을 막는 함수다. TypeScript에는 그 병이
//   없고(예외가 전파된다), 열거 의미론은 `repo-walk.ts`가 소유한다. 그 파일이 바닥값을 갖지 않기로
//   한 결정과 같은 경계다 — 열거자는 "글롭이 깨져 0건"과 "정당하게 0건"을 구별할 도메인 지식이 없다.
// `scan_count` — `grep -c .`가 0건일 때 rc=1이 되는 함정을 막는 함수다. TS에서는 `.length`다.
// 동형성은 함수 **개수**가 아니라 규약의 **의미**에서 지킨다. 병이 없는 자리에 함수를 만들면
// 그 자체가 얕은 모듈이다.
//
// ── 마커 문자열이 두 adapter에 리터럴로 있는 것에 대하여 ──────────────────────
// 같은 값이 두 자리에 리터럴로 사는 것은 이 레포가 반복해 밟은 형태다(그 일치를 확인하려고
// 소스를 정규식으로 파싱하는 테스트가 생긴다). 여기서 괜찮은 이유는 **실행 대조가 이미 있기**
// 때문이다 — `tests/gates/test_scan-floor.bats`가 셸 adapter 6종과 TS adapter 전량을 실제로 실행해
// 같은 정규식(`^SCAN: <라벨>: <숫자>$`)으로 방출을 파싱한다. 한쪽이 형태를 바꾸면 그 정규식이
// 못 잡아 즉시 red다. 실행 대조는 리터럴 대조보다 강하므로 생성 관계를 두지 않는다.
//
// ⚠️ 여기에 **건수를 적지 않는다.** 아무도 대조하지 않는 손 관리 수치는 반드시 드리프트한다
//    (셸 커널이 실측을 남겼다 — 주석은 "11종/27종", 실제는 13종/31종). 현재값이 필요하면 세어라.

/**
 * 커널이 판정에 실패했을 때 던지는 것. **커널은 종료하지 않는다** — 콜사이트가 이걸 잡아
 * 자기 도구의 종료코드로 번역한다(`tools/lib/` 커널 규율).
 */
export class ScanError extends Error {
  /**
   * 권고 종료코드. `1` = 열거 붕괴(검증 실패) · `2` = 임계값이 수가 아님(사용법 오류).
   * 콜사이트가 자기 값으로 덮어쓸 수 있다 — 셸 콜사이트가 `|| exit 1`과 `|| exit 2`로 갈리듯이.
   */
  readonly exitCode: number;
  constructor(message: string, exitCode: number) {
    super(message);
    this.name = "ScanError";
    this.exitCode = exitCode;
  }
}

export type ScanOpts = {
  /** stdout 마커만 억제한다. 바닥값 검사와 진단은 그대로다. */
  quiet?: boolean;
  /**
   * 바닥값 실패 진단에 덧붙일 도메인 힌트("정규식 드리프트·스코프 변경" 같은 것).
   * 셸 adapter에는 없다 — 거기 콜사이트는 애초에 힌트를 갖고 있지 않았다. TS 콜사이트는 갖고
   * 있었고, 커널이 종료를 소유하면 콜사이트가 뒤에 한 줄 더 낼 수 없으므로 그 지식을 여기로
   * 넘긴다. 마커 형태와 방출 순서는 그대로라 동형성은 유지된다.
   */
  hint?: string;
};

/**
 * 신호만 내는 자리는 억제만 받는다. `ScanOpts`를 통째로 받으면 `{ exitCode: 2 }`를 넘겨도 조용히
 * 무시되어, 호출자가 종료코드를 정했다고 믿는 자리가 생긴다.
 */
export type SignalOpts = Pick<ScanOpts, "quiet">;

/**
 * `SCAN: <라벨>: <n>` — 실행 관측용 균일 신호. **stdout**(SKIP 마커와 같은 채널).
 * 바닥값이 걸리지 않은 카운트 자리도 이걸 직접 부른다(예: check-guard-authority의 venues —
 * 바닥값은 권위 venue 수에 걸리고 신호는 전체 venue 수를 낸다).
 */
export function scanSignal(label: string, n: number, opts: SignalOpts = {}): void {
  if (opts.quiet) return;
  console.log(`SCAN: ${label}: ${n}`);
}

/**
 * raw 문자열을 바닥값 수로 판정한다. **`Number()` 앞에 서는 것이 이 함수의 존재 이유다** —
 * `Number("")`는 0이라, coercion 뒤에 검증하면 빈 입력과 **의도적 0**을 구별할 수 없다.
 * 그리고 0은 정당한 바닥값이라 금지해서 피할 수도 없다(셸 선례: `APP_DEPLOY_MIN_SCAN:-0`,
 * "앱이 0개인 동안은 레인2 열거 0건이 정당하다").
 *
 * 종료코드 2 = 사용법 오류(`cli.ts`의 종료코드 규약). 바닥값 실패(1)와 다른 사고다 —
 * "바닥값이 수가 아니다"와 "열거가 붕괴했다"는 원인 계층이 다르다.
 */
export function parseFloor(raw: string | undefined, source: string): number {
  if (raw === undefined || raw.trim() === "" || !/^\d+$/.test(raw.trim())) {
    throw new ScanError(`${source}는 음이 아닌 정수여야 한다(받은 값: '${raw ?? ""}')`, 2);
  }
  return Number(raw.trim());
}

/**
 * `ScanError`를 콜사이트의 진단 한 줄로 만든다. **문구는 커널이, 종료는 콜사이트가** 소유한다 —
 * `tools/README.md` 커널 표제가 "콜사이트가 정책 소유, **단 정책이 콜사이트마다 갈릴 때**"이고,
 * 여기서 실제로 갈리는 정책은 **진단 접두 하나**뿐이다(대부분 `FAIL:`, check-disk-caps는
 * GitHub Actions 어노테이션 `::error::disk-caps:`). 나머지는 전부 같으므로 커널이 갖는다 —
 * `lib/sealed-contract.ts`가 "정책이 갈리지 않으면 에러 문구까지 커널이 갖는다"로 세운 선례다.
 *
 * 이것이 없으면 콜사이트마다 `if (e instanceof ScanError) { console.error(…); process.exit(…) }`가
 * 복제된다(실측: 5벌 중 4벌이 주석까지 바이트 동일했다 — 원장 행 파서 3벌 사례와 같은 형태).
 *
 * 콜사이트 관용구는 **한 줄**이다: `catch (e) { process.exit(reportScanError(e, "FAIL:")); }`
 * — 진단을 내고 권고 코드를 돌려줄 뿐, **종료는 콜사이트가 한다**(lib은 종료를 소유하지 않는다).
 * `ScanError`가 아니면 되던진다: 커널이 삼키면 다른 결함이 이 자리에서 조용히 사라진다.
 */
export function reportScanError(e: unknown, prefix: string): number {
  if (!(e instanceof ScanError)) throw e;
  console.error(`${prefix} ${e.message}`);
  return e.exitCode;
}

/**
 * 상수로 주입되는 자리(`const MIN_SCAN = 30`)는 parseFloor를 거치지 않으므로, 그 경로를 덮는
 * 안전망이 필요하다. NaN·Infinity·소수·음수가 비교에 들어가면 `<`가 조용히 false가 된다.
 */
function requireCount(n: number, what: string): void {
  if (!Number.isSafeInteger(n) || n < 0) {
    throw new ScanError(`${what}가 음이 아닌 정수가 아니다(받은 값: ${String(n)}) — 판정 불가(fail-closed).`, 2);
  }
}

/**
 * 건수 바닥값. 미만이면 진단 + 종료(기본 1), 통과하면 SCAN 신호를 낸다.
 * **바닥값과 신호가 한 몸인 것이 요점이다** — 둘을 떼어 놓으면 그 사이에 무엇이든 낄 수 있고,
 * `check-disk-caps`에 낀 것이 위반 exit이었다(위반 실행에서 마커가 0건이 됐다).
 */
export function scanFloor(label: string, got: number, min: number, opts: ScanOpts = {}): void {
  requireCount(got, `${label}: 실제 건수`);
  requireCount(min, `${label}: 바닥값`);
  if (got < min) {
    const hint = opts.hint ? ` ${opts.hint}` : "";
    throw new ScanError(`${label}: 스캔 ${got}건 < ${min} — 열거 붕괴 의심(0건 검사 후 초록이 되는 자리).${hint}`, 1);
  }
  scanSignal(label, got, opts);
}

// ── 실행 커널 guardMain (lib-convergence 17 — 06/13의 재접목) ─────────────────────────────────
// 순서가 곧 계약이다: **전 도메인 열거 → 전 floor 판정 → (전부 통과 시에만) SCAN 일괄 방출 →
// 검사 → 종료코드.** 콜사이트가 순서를 손으로 맞추던 시절의 실측 버그 2건 — 위반 exit가 마커보다
// 앞(check-disk-caps) · 마커가 바닥값 판정보다 앞(check-alert-rules) — 이 이 구조에서는 표현
// 불가능하다. 붕괴한 실행의 건수는 "검사했다"가 아니라 "붕괴했다"는 뜻이므로, floor가 하나라도
// 무너지면 어느 도메인의 마커도 내지 않는다(일괄 방출).
//
// 위 판정 커널(scanFloor·scanSignal·parseFloor)과의 관계: guardMain은 판정을 **재사용**한다 —
// floor 판정·문구는 scanFloor(quiet)가, 마커 방출은 scanSignal이, --floor 값 검증은 parseFloor가
// 소유한다. 커널 둘이 문구 두 벌을 만들면 소비자가 grep을 두 벌 들게 된다. 위 커널은 "종료하지
// 않는다"가 규약이지만 guardMain은 **실행 진입 함수**라 exit를 소유한다(반환형 never가 계약이다).
//
// 소유 경계(셸 커널과 동일): 바닥값 수치와 위반·성공의 문구·채널은 콜사이트 소유, 실행 순서·
// 마커 모양·floor/열거 실패 진단(stderr `FAIL:`)은 커널 소유.
// `scan` 필드는 마커 라벨 **전체**를 콜사이트 리터럴로 받는다(도메인이 하나면 접미사 없음 —
// 셸 커널 규약) — tests/gates/test_scan-floor.bats의 정적 콜사이트 ↔ 런타임 방출 집합 대조가
// 이 리터럴(`scan: "…"`)을 파생하므로, 라벨을 변수로 조립하면 그 대조가 원리적으로 못 본다.
export type ScanDomain = {
  scan: string;             // 마커 라벨 전체 — 반드시 콜사이트 리터럴(정적 파생 대상)
  min: number;              // 열거 붕괴 바닥값 — 수치는 소비자 소유(커널은 판정 기계만 공유)
  enumerate: () => number;  // 열거 실행 — 검사 대상 건수 반환(위반 수집은 콜사이트 클로저)
  floorHint?: string;       // 붕괴의 그럴듯한 원인 진단 꼬리 — 콜사이트 소유(scanFloor hint로 전달)
};

// 바닥값 오버라이드 어휘: `--floor <도메인>=<n>`(반복 가능). 구 개별 어휘(env·--min-* 플래그)를
// 이 하나로 접는다 — 소비자 목록은 여기 적지 않는다(손 관리 로스터 금지: guardMain 콜사이트가
// SSOT다, `grep -l takeFloors tools/*.ts`로 세라). 키는 도메인 scan 라벨 전체 또는 마지막 콜론
// 뒤 접미사. 형식 위반은 ScanError(2) throw — 콜사이트가 reportScanError로 접는다. 기본값(min)은
// 콜사이트 상수가 소유하고, 키↔도메인 매칭 검증은 guardMain이 한다(오타 키 = 조용히 꺼진
// 바닥값이 되므로 fail-closed).
export function takeFloors(argv: string[]): { floors: Map<string, number>; rest: string[] } {
  const floors = new Map<string, number>();
  const rest: string[] = [];
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] !== "--floor") { rest.push(argv[i]!); continue; }
    const spec = argv[++i];
    const m = /^([a-z0-9:-]+)=(.*)$/.exec(spec ?? "");
    if (!m) throw new ScanError(`--floor 형식은 <도메인>=<n>이다(받은 값: '${spec ?? ""}')`, 2);
    floors.set(m[1]!, parseFloor(m[2], `--floor ${m[1]}`));
  }
  return { floors, rest };
}

export function floorOf(floors: Map<string, number>, scan: string, dflt: number): number {
  return floors.get(scan) ?? floors.get(scan.split(":").pop()!) ?? dflt;
}

export function guardMain(opts: {
  // 가드 식별자 — 도메인 라벨과 별개다("라벨 = 열거 도메인 하나" 규약상 도메인 라벨을 검사
  // 실패 같은 비-도메인 진단에 참칭하면 안 된다). 다중 도메인 가드는 지정하라.
  label?: string;
  domains: ScanDomain[];
  // takeFloors 산출 — 있으면 커널이 유효 min을 해소한다(floorOf). 키는 선언 도메인에 **전건
  // 매칭**돼야 한다: 오타·타 가드 키가 조용히 무시되면 바닥값이 소리 없이 꺼진다(구 typedFlags
  // 화이트리스트가 잡던 fail-closed의 복원). 미매칭·모호(2개 이상 매칭)는 사용법 exit(2)다.
  floors?: Map<string, number>;
  // 방출 정책 — **명시 필수**(design r1-3: 기본값에 숨기지 않는다). "none"은 기계 판독 stdout
  // 모드 전용이며 마커만 끄고 floor 판정·fail-closed는 그대로다.
  output: "stdout" | "none";
  check: () => string[];       // 위반 목록 — 비었으면 통과
  report: (viol: string[]) => void; // 위반 문구·채널 — 콜사이트 소유
  ok: (counts: number[]) => void;   // 성공 문구 — 콜사이트 소유
}): never {
  // ⓪ --floor 키 검증(도메인 전건 매칭) — 열거보다 먼저다: 잘못된 호출은 일을 시작하기 전에 죽는다.
  const floors = opts.floors ?? new Map<string, number>();
  for (const k of floors.keys()) {
    const hits = opts.domains.filter((d) => d.scan === k || d.scan.split(":").pop() === k);
    if (hits.length === 0) {
      console.error(
        `--floor 도메인 '${k}'가 이 가드의 선언 도메인에 없다(허용: ${opts.domains.map((d) => d.scan).join(" · ")}) — 오타 키는 조용히 꺼진 바닥값이 된다(fail-closed)`,
      );
      process.exit(2);
    }
    if (hits.length > 1) {
      console.error(`--floor 도메인 '${k}'가 ${hits.length}개 도메인에 걸린다(${hits.map((d) => d.scan).join(" · ")}) — 전체 라벨로 지정하라`);
      process.exit(2);
    }
  }
  // ① 전 도메인 열거. throw는 fail-loud로 접는다 — raw 스택이 나가면 게이트 출력 규약이 깨진다.
  const counts: number[] = [];
  for (const d of opts.domains) {
    try {
      counts.push(d.enumerate());
    } catch (e) {
      console.error(`FAIL: ${d.scan}: 열거 실패 — ${e instanceof Error ? e.message : String(e)}`);
      process.exit(1);
    }
  }
  // ② 전 floor 판정 — 하나라도 무너지면 전부 보고하고 마커 없이 죽는다. 판정·문구는 scanFloor
  //    재사용이다(quiet: 통과 도메인의 마커는 ③에서 일괄 방출하므로 여기선 내지 않는다).
  const collapsed: string[] = [];
  let collapseCode = 1;
  opts.domains.forEach((d, i) => {
    try {
      scanFloor(d.scan, counts[i]!, floorOf(floors, d.scan, d.min), { quiet: true, hint: d.floorHint });
    } catch (e) {
      if (!(e instanceof ScanError)) throw e;
      collapsed.push(`FAIL: ${e.message}`);
      if (e.exitCode > collapseCode) collapseCode = e.exitCode;   // 계약 파손(2)은 붕괴(1)보다 우선
    }
  });
  if (collapsed.length) {
    for (const c of collapsed) console.error(c);
    process.exit(collapseCode);
  }
  // ③ SCAN 일괄 방출(정책이 stdout일 때만) — 도메인 선언 순서 그대로, 방출 구현은 scanSignal 하나다.
  if (opts.output === "stdout") {
    opts.domains.forEach((d, i) => scanSignal(d.scan, counts[i]!));
  }
  // ④ 검사 → ⑤ 종료코드. 검사 단계의 예외도 커널이 접는다(raw 스택 금지 — 마커는 이미
  // 방출된 뒤라 붕괴 경로와 구별된다).
  let viol: string[];
  try {
    viol = opts.check();
  } catch (e) {
    console.error(`FAIL: ${opts.label ?? opts.domains[0]?.scan ?? "guard"}: 검사 실패 — ${e instanceof Error ? e.message : String(e)}`);
    process.exit(1);
  }
  if (viol.length) {
    opts.report(viol);
    process.exit(1);
  }
  opts.ok(counts);
  process.exit(0);
}
