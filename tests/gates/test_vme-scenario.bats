#!/usr/bin/env bats
# 발화 e2e 시나리오 interface(lib-convergence d5 — vme_scenario/vme_leg)의 계약 테스트.
# 마찰의 근원은 전역 VME_*가 아니라 **암묵 순서**였다(체이닝 레이스 2건 전부 순서 사고) — 그래서
# 조립 순서(derive → workspace → 룰 추출 · 레그의 start → import)를 lib 내부로 접고, 하네스는
# 시나리오 호출 1개로 기동한다. 전역 VME_* 출력 변수는 유지한다(소비자 계약 불변).
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과. @test 이름은 영어(CJK 함정).

LIB="tests/gates/lib/vmalert-e2e.sh"

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  cd "$ROOT" || exit 1
  # docker 스텁 — vme_scenario의 workspace가 docker network create를 부르지만 이 단위 계약엔 실 데몬이
  # 필요 없다(형제 test_vmalert-e2e-port-allocation.bats의 PATH 스텁 관용구). 정리(rm)도 no-op.
  STUB="$BATS_TEST_TMPDIR/bin"; mkdir -p "$STUB"
  printf '#!/bin/sh\nexit 0\n' > "$STUB/docker"
  chmod +x "$STUB/docker"
}

# 발화 하네스 열거는 레포에서 파생한다(CONTRIBUTING — 소비처 하드코딩 금지). 예외 없음(09에서
# bulkssd까지 흡수 완료 — 발화 e2e 전 종이 시나리오 경유다).
harnesses() {
  git ls-files 'tests/gates/vmalert-*-firing-e2e.sh'
}

# ── vme_scenario 계약(단위 — docker는 PATH 스텁: 네트워크 기동의 실증은 발화 e2e 5종이 갖는다) ─────
# 픽스처 스택 디렉토리·룰 ConfigMap을 만들어 실제로 호출하고, 파생·추출·fail-closed 축을 잰다.

fixture_stack() {
  S="$BATS_TEST_TMPDIR/stack"; mkdir -p "$S"
  printf 'image: victoriametrics/vmalert:v1.99.0\nargs:\n  - --evaluationInterval=30s\n  - --datasource.queryStep=2m\n' > "$S/vmalert.yaml"
  printf 'image: victoriametrics/victoria-metrics:v1.99.0\n' > "$S/vmsingle.yaml"
  CM="$BATS_TEST_TMPDIR/rules-cm.yaml"
  printf 'data:\n  r9.yaml: |\n    groups:\n      - name: g\n        rules:\n          - alert: Demo\n            expr: up == 0\n' > "$CM"
}

@test "vme_scenario derives stack params, makes the workspace, and extracts the deployed rules in one call" {
  fixture_stack
  run env PATH="$STUB:$PATH" bash -c '
    set -euo pipefail
    . '"$LIB"'
    vme_scenario "vme-scn-test-$$" "'"$S"'" "'"$CM"'" "r9.yaml"
    echo "va=$VME_VA_VER vm=$VME_VM_VER eval=$VME_EVAL lookback=$VME_LOOKBACK"
    echo "rules=$VME_RULES"
    grep -q "alert: Demo" "$VME_RULES" && echo "rules-extracted=yes"
    [ -d "$VME_TMP" ] && echo "workspace=yes"
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^va=v1.99.0 vm=v1.99.0 eval=30s lookback=2m$'
  echo "$output" | grep -q '^rules-extracted=yes$'
  echo "$output" | grep -q '^workspace=yes$'
}

@test "vme_scenario fails closed when the rules key is absent from the ConfigMap (no empty-rules green)" {
  fixture_stack
  run env PATH="$STUB:$PATH" bash -c '
    set -euo pipefail
    . '"$LIB"'
    vme_scenario "vme-scn-test2-$$" "'"$S"'" "'"$CM"'" "no-such-key.yaml"
  '
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "룰 추출 실패"
}

# ── 하네스 5개의 조립 나열 소거(정적) — AC 1·3의 이빨 ────────────────────────────────────────────
@test "all migrated firing harnesses boot through vme_scenario (no inline assembly enumeration)" {
  n=0
  for h in $(harnesses); do
    # 호출 카운트는 행두 앵커드다 — 주석 속 언급이 실제 호출의 삭제를 가리면 안 된다(fail-open 봉쇄).
    run grep -cE '^[[:space:]]*vme_scenario ' "$h"
    [ "$output" = "1" ] || { echo "assembly drift: ${h}의 vme_scenario 호출이 ${output}회(기대 1)"; false; }
    # 조립 함수의 직접 나열이 사라졌다 — 순서 의존이 호출자에서 lib 내부로 이동했다는 그 사실(주석 포함 0).
    for fn in vme_derive_stack_params vme_workspace; do
      run grep -c "$fn" "$h"
      [ "$output" = "0" ] || { echo "assembly drift: ${h}가 ${fn}을 직접 나열한다(${output}곳) — 순서 의존이 호출자로 되돌아왔다"; false; }
    done
    # 레그 미니-조립(start → import)도 vme_leg가 소유한다.
    run grep -c 'vme_start_vmsingle\|vme_import' "$h"
    [ "$output" = "0" ] || { echo "assembly drift: ${h}가 레그 조립(start/import)을 직접 나열한다(${output}곳)"; false; }
    run grep -cE '^[[:space:]]*vme_leg ' "$h"
    [ "$output" = "1" ] || { echo "assembly drift: ${h}의 vme_leg 호출이 ${output}회(기대 1 — 레그 함수 안 한 곳)"; false; }
    n=$((n + 1))
  done
  [ "$n" -ge 6 ]   # 열거 붕괴 바닥값 — glob이 깨지면 루프가 vacuous해진다
}

@test "vme_leg owns the start-then-import order (start before import, both inside the lib)" {
  # lib 안에서 vme_leg가 start와 import를 이 순서로 소유한다 — 라인 번호 비교(정적).
  body_start="$(grep -n '^vme_leg()' "$LIB" | cut -d: -f1)"
  [ -n "$body_start" ] || { echo "vme_leg가 lib에 없다"; false; }
  in_leg_start="$(awk 'NR>'"$body_start"' && /vme_start_vmsingle/ {print NR; exit}' "$LIB")"
  in_leg_import="$(awk 'NR>'"$body_start"' && /vme_import/ {print NR; exit}' "$LIB")"
  [ -n "$in_leg_start" ]
  [ -n "$in_leg_import" ]
  [ "$in_leg_start" -lt "$in_leg_import" ]
}
