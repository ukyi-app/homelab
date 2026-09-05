#!/usr/bin/env bats
# TS 가드 실행 커널 guardMain(tools/lib/scan-floor.ts, lib-convergence 17 재접목)의 순서 계약 테스트.
# 순서가 곧 계약이다: 전 도메인 열거 → 전 floor 판정 → (전부 통과 시에만) SCAN 일괄 방출 →
# 검사 → 종료코드. 콜사이트가 순서를 손으로 맞추던 시절의 실측 버그 2건(위반 exit가 마커보다
# 앞 · 마커가 바닥값보다 앞)이 이 구조에서 표현 불가능함을 픽스처 가드로 고정한다.
# 판정·문구·마커는 origin 커널(scanFloor·scanSignal·parseFloor)을 재사용한다 — 커널 둘이
# 문구 두 벌을 만들면 소비자가 grep을 두 벌 들게 된다(17 재접목 조건).
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과. @test 이름은 영어(CJK 함정).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  FX="$BATS_TEST_TMPDIR/g.ts"
  # 픽스처 가드: 도메인 2개(fx:alpha·fx:beta), 열거/바닥값/위반/방출 정책을 env로 조종한다.
  # ⚠️ heredoc은 비인용(EOF) — $ROOT 확장이 필요하다. TS 본문은 ${} 템플릿 리터럴을 쓰지 않는다.
  cat > "$FX" <<EOF
import { guardMain, takeFloors } from "$ROOT/tools/lib/scan-floor.ts";
const taken = takeFloors(process.argv.slice(2));
guardMain({
  label: process.env.FX_LABEL || undefined,
  floors: taken.floors,
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
  # 문구는 origin scanFloor 소유다("스캔 N건 < M — 열거 붕괴 의심(…)") — 커널 둘이 문구 두 벌을
  # 만들면 안 되므로 guardMain은 판정·문구를 scanFloor 재사용으로 얻는다.
  echo "$output" | grep -q '스캔 0건'
  echo "$output" | grep -q '< 7'
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

@test "the floor override vocabulary parses repeated --floor and strips it from argv" {
  # 어휘 통일(d1): 구 어휘(env·--min-* 플래그·상수)를 `--floor <도메인>=<n>` 하나로 접는다.
  # 키는 scan 라벨 전체 또는 마지막 콜론 뒤 접미사 — floorOf가 그 순서로 해소한다.
  run bun -e '
    import { takeFloors, floorOf } from "'"$ROOT"'/tools/lib/scan-floor.ts";
    const { floors, rest } = takeFloors(["--floor", "caps=3", "--repo-root", "x", "--floor", "check-g:refs=7"]);
    console.log(rest.join(","));
    console.log(floorOf(floors, "check-disk-caps:caps", 99));
    console.log(floorOf(floors, "check-g:refs", 99));
    console.log(floorOf(floors, "check-g:other", 42));
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^--repo-root,x$'
  echo "$output" | grep -q '^3$'
  echo "$output" | grep -q '^7$'
  echo "$output" | grep -q '^42$'
}

@test "a --floor override raises the effective floor through the kernel (no callsite lookup)" {
  # floors는 guardMain 인자다 — 콜사이트가 floorOf를 기억해 부르는 구조는 잊힌 도메인만
  # 조용히 오버라이드 불가가 되는 자리였다(실측: 배선 누락 2가드).
  run bun "$FX" --floor alpha=7
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'fx:alpha: 스캔 3건 < 7'
}

@test "an unmatched --floor domain key is a usage error, not a silently disabled floor" {
  # 오타 키가 조용히 무시되면 바닥값이 소리 없이 꺼진다 — 구 typedFlags 화이트리스트가 잡던
  # fail-closed의 복원(커널이 선언 도메인과 전건 매칭을 검증한다).
  run bun "$FX" --floor bogus=9999
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "bogus"
  echo "$output" | grep -q "조용히 꺼진 바닥값"
}

@test "a --floor key matching two domains is rejected as ambiguous" {
  FX2="$BATS_TEST_TMPDIR/g2.ts"
  cat > "$FX2" <<EOF
import { guardMain, takeFloors } from "$ROOT/tools/lib/scan-floor.ts";
const taken = takeFloors(process.argv.slice(2));
guardMain({
  floors: taken.floors,
  domains: [
    { scan: "fx:dup", min: 1, enumerate: () => 3 },
    { scan: "gx:dup", min: 1, enumerate: () => 3 },
  ],
  output: "stdout",
  check: () => [],
  report: () => {},
  ok: () => { console.log("ok"); },
});
EOF
  run bun "$FX2" --floor dup=5
  [ "$status" -eq 2 ]
  echo "$output" | grep -q '전체 라벨로 지정하라'
  run bun "$FX2" --floor fx:dup=5
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'fx:dup: 스캔 3건 < 5'
}

@test "a malformed --floor value fails loud (empty and non-numeric are both rejected)" {
  # 값 검증은 origin parseFloor 재사용이다 — `Number("")===0`이라 coercion 뒤 검증은 빈 입력과
  # 의도적 0을 구별하지 못한다(TS 바닥값 함정 원장).
  run bun -e '
    import { takeFloors } from "'"$ROOT"'/tools/lib/scan-floor.ts";
    try { takeFloors(["--floor", "caps="]); } catch (e) { console.error("E1 " + (e as Error).message); }
    try { takeFloors(["--floor", "abc"]); } catch (e) { console.error("E2 " + (e as Error).message); }
    try { takeFloors(["--floor"]); } catch (e) { console.error("E3 " + (e as Error).message); }
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^E1 .*음이 아닌 정수'
  echo "$output" | grep -q '^E2 '
  echo "$output" | grep -q '^E3 '
}

@test "an empty domains array is a usage error, not a silently floor-free guard" {
  # 리뷰 실측(17): 도메인 0개인 가드는 floor도 마커도 없이 초록이 되고, 정적 로스터와 런타임
  # 파일 목록에서 **동시에** 빠져 집합 등식이 그대로 성립한다 — 삭제 구멍을 커널이 닫는다.
  FX0="$BATS_TEST_TMPDIR/g0.ts"
  cat > "$FX0" <<EOF
import { guardMain } from "$ROOT/tools/lib/scan-floor.ts";
guardMain({ domains: [], output: "stdout", check: () => [], report: () => {}, ok: () => { console.log("EMPTY-OK"); } });
EOF
  run bun "$FX0"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "domains가 비었다"
  out="$output"
  run grep -q "EMPTY-OK" <<<"$out"
  [ "$status" -ne 0 ]
}

@test "a non-numeric floor constant dies as contract breakage (exit 2), not as collapse (exit 1)" {
  # collapseCode 승격의 증인 — min이 NaN이면 requireCount(ScanError 2)가 걸리고, 붕괴(1)로
  # 오분류되면 "계약 파손"과 "열거 붕괴"라는 다른 원인 계층이 한 코드로 뭉개진다.
  FX_MIN_A=abc run bun "$FX"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "음이 아닌 정수"
  out="$output"
  run grep -q '^SCAN: ' <<<"$out"
  [ "$status" -ne 0 ]
}

@test "contract breakage outranks collapse when both domains fail in the same run (breakage second)" {
  # lib-b-2 — collapseCode의 '계약파손(2) > 붕괴(1)' 우선순위(scan-floor.ts:272 if (e.exitCode >
  # collapseCode))를 실행하는 다중도메인 동시실패 픽스처가 없었다(기존 #14는 alpha 단일 도메인만
  # 실패시켜 beta는 통과 — 우선순위 분기 자체가 실행되지 않는다). alpha=붕괴(exit1) 먼저,
  # beta=계약파손(exit2, min이 NaN)이 나중이어도 최종 종료코드는 2여야 한다.
  FX_N_A=0 FX_MIN_B=abc run bun "$FX"
  [ "$status" -eq 2 ]
}

@test "contract breakage outranks collapse regardless of which domain is processed first (breakage first)" {
  # 위 테스트의 순서 반전 — alpha=계약파손(exit2) 먼저, beta=붕괴(exit1)가 나중이어도 여전히 2.
  # min/enumerate가 하드코딩 정수·.length뿐인 현재 실 가드에서는 도달 불가 경로이며, 미래 동적
  # min을 쓰는 새 도메인이 추가될 때 이 우선순위 역전을 잡는 회귀 방지용이다.
  FX_MIN_A=abc FX_N_B=0 run bun "$FX"
  [ "$status" -eq 2 ]
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

@test "assertFloorKeys is a first-class contract for kernel-vocabulary-only consumers" {
  # guardMain 밖 소비자(어휘만 소비·마커 미방출 — kernel-followups 05)의 fail-closed가 이 함수
  # 하나에 걸린다 — ScanError(2) throw(takeFloors와 같은 오류 규율, 종료·접두는 콜사이트 소유).
  run bun -e '
    import { ScanError, assertFloorKeys, takeFloors } from "'"$ROOT"'/tools/lib/scan-floor.ts";
    const ok = takeFloors(["--floor", "reserved=3"]).floors;
    assertFloorKeys(ok, ["demo:reserved"]);
    console.log("valid-ok");
    try { assertFloorKeys(takeFloors(["--floor", "bogus=1"]).floors, ["demo:reserved"]); }
    catch (e) { if (e instanceof ScanError) console.error("E1 code=" + e.exitCode + " " + e.message); }
    try { assertFloorKeys(takeFloors(["--floor", "dup=1"]).floors, ["a:dup", "b:dup"]); }
    catch (e) { if (e instanceof ScanError) console.error("E2 code=" + e.exitCode); }
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^valid-ok$"
  echo "$output" | grep -q "^E1 code=2 .*조용히 꺼진 바닥값"
  echo "$output" | grep -q "^E2 code=2$"
}
