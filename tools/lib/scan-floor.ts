// TS 가드 실행 커널 — 셸 커널 scripts/lib/scan-floor.sh의 TS 이식(lib-convergence d1).
// 순서가 곧 계약이다: **전 도메인 열거 → 전 floor 판정 → (전부 통과 시에만) SCAN 일괄 방출 →
// 검사 → 종료코드.** 콜사이트가 순서를 손으로 맞추던 시절의 실측 버그 2건 — 위반 exit가 마커보다
// 앞(check-disk-caps) · 마커가 바닥값 판정보다 앞(check-alert-rules) — 이 이 구조에서는 표현
// 불가능하다. 붕괴한 실행의 건수는 "검사했다"가 아니라 "붕괴했다"는 뜻이므로, floor가 하나라도
// 무너지면 어느 도메인의 마커도 내지 않는다(일괄 방출).
//
// 소유 경계(셸 커널과 동일): 바닥값 수치와 위반·성공의 문구·채널은 콜사이트 소유, 실행 순서·
// 마커 모양·floor/열거 실패 진단(stderr `FAIL:` — 셸 커널과 같은 어휘)은 커널 소유.
// `scan` 필드는 마커 라벨 **전체**를 콜사이트 리터럴로
// 받는다(도메인이 하나면 접미사 없음 — 셸 커널 규약) — tests/gates/test_scan-floor.bats의
// 정적 콜사이트 ↔ 런타임 방출 집합 대조가 이 리터럴(`scan: "…"`)을 파생하므로, 라벨을 변수로
// 조립하면 그 대조가 원리적으로 못 본다.
export type ScanDomain = {
  scan: string;             // 마커 라벨 전체 — 반드시 콜사이트 리터럴(정적 파생 대상)
  min: number;              // 열거 붕괴 바닥값 — 수치는 소비자 소유(커널은 판정 기계만 공유)
  enumerate: () => number;  // 열거 실행 — 검사 대상 건수 반환(위반 수집은 콜사이트 클로저)
  floorHint?: string;       // 붕괴의 그럴듯한 원인 진단 꼬리 — 콜사이트 소유
};

export function guardMain(opts: {
  domains: ScanDomain[];
  // 방출 정책 — **명시 필수**(design r1-3: 기본값에 숨기지 않는다). "none"은 기계 판독 stdout
  // 모드 전용이며 마커만 끄고 floor 판정·fail-closed는 그대로다.
  output: "stdout" | "none";
  check: () => string[];       // 위반 목록 — 비었으면 통과
  report: (viol: string[]) => void; // 위반 문구·채널 — 콜사이트 소유
  ok: (counts: number[]) => void;   // 성공 문구 — 콜사이트 소유
}): never {
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
  // ② 전 floor 판정 — 하나라도 무너지면 전부 보고하고 마커 없이 죽는다.
  const collapsed: string[] = [];
  opts.domains.forEach((d, i) => {
    if (counts[i]! < d.min) {
      // 어휘는 셸 커널 scan_floor와 같다("스캔 N건 < M — 열거 붕괴 의심") — 두 커널이 두 문구를
      // 만들면 소비자가 grep을 두 벌 들게 된다.
      collapsed.push(
        `FAIL: ${d.scan}: 스캔 ${counts[i]}건 < ${d.min} — 열거 붕괴 의심` +
          (d.floorHint ? `(${d.floorHint})` : ""),
      );
    }
  });
  if (collapsed.length) {
    for (const c of collapsed) console.error(c);
    process.exit(1);
  }
  // ③ SCAN 일괄 방출(정책이 stdout일 때만) — 도메인 선언 순서 그대로.
  if (opts.output === "stdout") {
    opts.domains.forEach((d, i) => console.log(`SCAN: ${d.scan}: ${counts[i]}`));
  }
  // ④ 검사 → ⑤ 종료코드.
  const viol = opts.check();
  if (viol.length) {
    opts.report(viol);
    process.exit(1);
  }
  opts.ok(counts);
  process.exit(0);
}
