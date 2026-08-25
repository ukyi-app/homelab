#!/usr/bin/env bats
# 디스크 자기-상한 ↔ 볼륨 선언 정합 게이트(D-4)의 회귀 가드.
#
# ⚠️ 이 게이트가 필요한 이유는 **존재 grep이 이 클래스를 못 잡기 때문**이다.
#    `tests/gates/test_vmalert-config.bats`가 이미 `maxDiskUsagePerURL` **존재**를 보는데,
#    450MiB를 900MiB로 바꿔도 초록이고 victorialogs의 15GB > 10Gi도 못 잡았다.
#    규범은 `docs/traps-detail.md`에 문장으로 있었다 — 빠진 것은 규범이 아니라 **강제**다.
#
# ⚠️ 판정 로직은 **픽스처 트리**에서 실증한다(실 파일을 변이하지 않는다). 실 파일을 sed로 바꿨다가
#    되돌리는 방식은 테스트가 중간에 죽으면 워킹트리에 잔재를 남긴다 — 이 레포가 실제로 겪은 사고다.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2에서 [[ ]] 실패는 침묵 통과.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1
  TOOL="$ROOT/tools/check-disk-caps.ts"
}

# $1=cap 문자열 $2=볼륨 선언 문자열(빈 값이면 볼륨 선언 없음) → 픽스처 경로를 stdout으로
mkfx() {
  fx="$BATS_TEST_TMPDIR/fx-$BATS_TEST_NUMBER"
  mkdir -p "$fx/platform/x/prod"
  {
    echo "kind: PersistentVolumeClaim"
    echo "spec:"
    if [ -n "$2" ]; then echo "  resources: { requests: { storage: $2 } }"; else echo "  resources: {}"; fi
    echo "---"
    echo "kind: StatefulSet"
    echo "spec:"
    echo "  template:"
    echo "    spec:"
    echo "      containers:"
    echo "        - args: [--retention.maxDiskSpaceUsageBytes=$1]"
  } > "$fx/platform/x/prod/w.yaml"
  git -C "$fx" init -q
  git -C "$fx" add -A
  printf '%s' "$fx"
}

@test "the repo passes today (every disk cap is below its volume declaration)" {
  run bun "$TOOL"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^SCAN: check-disk-caps:caps: '
}

@test "GB and Gi are converted to bytes, not compared by suffix (this is the whole bug)" {
  # 15GB(1.50e10) > 10Gi(1.074e10). 접미사만 보면 "15 > 10"으로도 "GB < Gi"로도 잘못 읽힌다.
  # 비율 139.7%가 나온다는 것 자체가 **바이트 환산이 실제로 일어났다**는 증거다.
  fx="$(mkfx 15GB 10Gi)"
  cd "$fx" || false
  run bun "$TOOL" --floor caps=1
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '139.7%'
}

@test "a violation run still emits the SCAN marker (order: floor, then SCAN, then violations)" {
  # scan-floor 규약: 도메인을 평가한 실행은 위반 여부와 무관하게 신호를 낸다 — 면제는 바닥값
  # 실패 경로뿐. 위반 exit가 마커보다 앞서면 위반 실행이 "마커 부재 = 미실행"으로 오독된다.
  fx="$(mkfx 15GB 10Gi)"
  cd "$fx" || false
  run bun "$TOOL" --floor caps=1
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '^SCAN: check-disk-caps:caps: 1$'
}

@test "a cap below its volume declaration passes (the fix direction)" {
  fx="$(mkfx 8GB 10Gi)"
  cd "$fx" || false
  run bun "$TOOL" --floor caps=1
  [ "$status" -eq 0 ]
}

@test "equality is a violation too (cap == volume leaves zero margin)" {
  # 여유 0. BGSAVE류 순간 2배 사용을 생각하면 '같음'도 안전하지 않다.
  fx="$(mkfx 10Gi 10Gi)"
  cd "$fx" || false
  run bun "$TOOL" --floor caps=1
  [ "$status" -ne 0 ]
}

@test "a cap with no volume declaration in its file fails closed (nothing to compare)" {
  fx="$(mkfx 8GB "")"
  cd "$fx" || false
  run bun "$TOOL" --floor caps=1
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '무엇과 비교해야 하는지'
}

@test "the enumeration floor fires when discovery collapses" {
  # 바닥값이 없으면 정규식/스코프가 깨져 0건을 스캔하고도 "위반 0"으로 초록이 된다.
  run bun "$TOOL" --floor caps=99
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '열거 붕괴'
  # scan-floor 규약의 나머지 반쪽: 바닥값 실패 실행은 SCAN 면제 — 마커를 내면 "실행됨"으로 오독된다.
  out="$output"
  run grep -q '^SCAN: check-disk-caps:caps: ' <<<"$out"
  [ "$status" -ne 0 ]
}

@test "the guard runs in BOTH the required gate and make ci" {
  # 한쪽에만 있으면 회계가 반쪽이다(패리티 원장이 별도로 강제하지만 여기서도 못 박는다).
  run grep -q 'check-disk-caps.ts' "$ROOT/.github/workflows/ci.yaml"
  [ "$status" -eq 0 ]
  run make -n ci
  [ "$status" -eq 0 ]
  # 핵심 단언(마지막)
  echo "$output" | grep -q 'check-disk-caps.ts'
}
