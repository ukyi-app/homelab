#!/usr/bin/env bats
# TS 가드 실행 커널(tools/lib/scan-floor.ts, lib-convergence d1)의 순서 계약 테스트.
# 순서가 곧 계약이다: 전 도메인 열거 → 전 floor 판정 → (전부 통과 시에만) SCAN 일괄 방출 →
# 검사 → 종료코드. 콜사이트가 순서를 손으로 맞추던 시절의 실측 버그 2건(위반 exit가 마커보다
# 앞 · 마커가 바닥값보다 앞)이 이 구조에서 표현 불가능함을 픽스처 가드로 고정한다.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과. @test 이름은 영어(CJK 함정).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  FX="$BATS_TEST_TMPDIR/g.ts"
  # 픽스처 가드: 도메인 2개(fx:alpha·fx:beta), 열거/바닥값/위반/방출 정책을 env로 조종한다.
  # ⚠️ heredoc은 비인용(EOF) — $ROOT 확장이 필요하다. TS 본문은 ${} 템플릿 리터럴을 쓰지 않는다.
  cat > "$FX" <<EOF
import { guardMain } from "$ROOT/tools/lib/scan-floor.ts";
guardMain({
  label: process.env.FX_LABEL || undefined,
  domains: [
    { scan: "fx:alpha", min: Number(process.env.FX_MIN_A ?? "1"), floorHint: "fixture alpha hint",
      enumerate: () => {
        if (process.env.FX_THROW) throw new Error("fixture enumerate boom");
        return Number(process.env.FX_N_A ?? "3");
      } },
    { scan: "fx:beta", min: Number(process.env.FX_MIN_B ?? "1"),
      enumerate: () => Number(process.env.FX_N_B ?? "2") },
  ],
  output: (process.env.FX_OUTPUT ?? "stdout") as "stdout" | "none",
  check: () => {
    if (process.env.FX_CHECK_THROW) throw new Error("fixture check boom");
    return process.env.FX_VIOL ? ["v1"] : [];
  },
  report: (v) => { console.log("FAIL: fixture violations: " + v.join(",")); },
  ok: (c) => { console.log("fixture OK " + c.join("/")); },
});
EOF
}

@test "green path emits every domain marker before the ok line and exits 0" {
  run bun "$FX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^SCAN: fx:alpha: 3$'
  echo "$output" | grep -q '^SCAN: fx:beta: 2$'
  # 마커는 성공 문구보다 앞이다(방출 → 검사 → 문구 순서의 관측 가능한 그림자).
  first_scan="$(echo "$output" | grep -n '^SCAN: ' | head -1 | cut -d: -f1)"
  ok_line="$(echo "$output" | grep -n '^fixture OK' | cut -d: -f1)"
  [ "$first_scan" -lt "$ok_line" ]
}

@test "a violation run still emits every marker and exits 1 (violations never precede markers)" {
  FX_VIOL=1 run bun "$FX"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q '^SCAN: fx:alpha: 3$'
  echo "$output" | grep -q '^SCAN: fx:beta: 2$'
  scan_line="$(echo "$output" | grep -n '^SCAN: fx:alpha' | cut -d: -f1)"
  fail_line="$(echo "$output" | grep -n '^FAIL: fixture violations' | cut -d: -f1)"
  [ "$scan_line" -lt "$fail_line" ]
}

@test "one collapsed floor suppresses EVERY marker, not just its own domain" {
  # beta는 floor를 통과하지만 alpha가 붕괴하면 beta 마커도 안 나온다 — 일괄 방출 원칙.
  FX_N_A=0 run bun "$FX"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q '열거 붕괴'
  echo "$output" | grep -q 'fx:alpha'
  out="$output"
  run grep -q '^SCAN: ' <<<"$out"
  [ "$status" -ne 0 ]
}

@test "every collapsed floor is reported in one run (all floors are judged before exiting)" {
  FX_N_A=0 FX_N_B=0 run bun "$FX"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'fx:alpha'
  echo "$output" | grep -q 'fx:beta'
}

@test "the floor diagnostic names both numbers and carries the callsite hint" {
  FX_N_A=0 FX_MIN_A=7 run bun "$FX"
  [ "$status" -eq 1 ]
  # 어휘는 셸 커널 scan_floor와 동일해야 한다("스캔 N건 < M") — 커널 둘이 문구 두 벌을 만들면 안 된다.
  echo "$output" | grep -q '스캔 0건'
  echo "$output" | grep -q '7'
  echo "$output" | grep -q 'fixture alpha hint'
}

@test "an enumerate that throws fails loud with no marker (never a raw stack)" {
  FX_THROW=1 run bun "$FX"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q '열거 실패'
  echo "$output" | grep -q 'fixture enumerate boom'
  out="$output"
  run grep -q '^SCAN: ' <<<"$out"
  [ "$status" -ne 0 ]
}

@test "a check that throws fails loud after markers (never a raw stack)" {
  # 검사 단계의 예외도 커널이 접는다 — raw 스택은 게이트 출력 규약 위반이다. 마커는 이미
  # 방출된 뒤다(도메인 평가는 정상이었고 검사가 죽었을 뿐 — 붕괴 경로와 구별된다).
  FX_CHECK_THROW=1 run bun "$FX"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q '^SCAN: fx:alpha: 3$'
  echo "$output" | grep -q '검사 실패'
  echo "$output" | grep -q 'fixture check boom'
  # 가드 식별자(label)가 있으면 검사 실패 진단은 그것을 쓴다 — 도메인 라벨은 열거 도메인
  # 전용이라("라벨 = 열거 도메인 하나") 비-도메인 진단에 참칭하면 안 된다.
  FX_CHECK_THROW=1 FX_LABEL=fx-guard run bun "$FX"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q '^FAIL: fx-guard: 검사 실패'
}

@test "output:none keeps stdout free of markers while verdict semantics stay intact" {
  FX_OUTPUT=none run bun "$FX"
  [ "$status" -eq 0 ]
  out="$output"
  run grep -q '^SCAN: ' <<<"$out"
  [ "$status" -ne 0 ]
  # 억제 모드에서도 floor는 여전히 판정한다 — 방출 정책은 마커만 끄지 fail-closed를 끄지 않는다.
  FX_OUTPUT=none FX_N_A=0 run bun "$FX"
  [ "$status" -eq 1 ]
  # 위반 경로도 동일 — 마커만 없고 위반 보고와 exit 1은 그대로다.
  FX_OUTPUT=none FX_VIOL=1 run bun "$FX"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q '^FAIL: fixture violations'
  out="$output"
  run grep -q '^SCAN: ' <<<"$out"
  [ "$status" -ne 0 ]
}
