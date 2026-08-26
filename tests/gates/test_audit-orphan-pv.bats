#!/usr/bin/env bats
# 고아 Released PV 감사 — fail-closed(깨진 감사 ≠ 고아 없음, F7). ⚠️ 중간 단언 [ ]만.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "orphan-PV audit surfaces Released PVs and is fail-closed (broken audit != no orphans)" {
  S="$ROOT/scripts/audit-orphan-pv.sh"
  [ -x "$S" ]
  run grep -Eq 'status\.phase.*Released|"Released"' "$S"; [ "$status" -eq 0 ]      # Released 선택
  run grep -Eq 'command -v kubectl|command -v yq' "$S"; [ "$status" -eq 0 ]        # preflight
  run grep -Eq 'exit [23]' "$S"; [ "$status" -eq 0 ]                               # 실패는 비-0
  # 클러스터 없는 환경(CI)서 실행 → 비-0 + '고아 없음' 미출력(깨진 감사를 깨끗한 결과로 위장 안 함)
  run bash "$S"
  [ "$status" -ne 0 ]
  run grep -q '고아 없음' <<< "$output"
  [ "$status" -ne 0 ]   # 클러스터 부재 출력에 '고아 없음'이 있으면 실패(혼동 방지)
}

@test "an unreachable cluster is the skip convention, not a hard failure (kernel-followups 03)" {
  # 의미론 전환의 증인 — 접근·도구 부재는 red(2/3)가 아니라 skip(4 + 마커)이다. 로스터 등식
  # 게이트가 이 가드를 SKIP 대칭으로 제외하는 근거가 바로 이 rc다(venue 갈림 방지).
  run env KUBECONFIG=/nonexistent/kubeconfig bash "$ROOT/scripts/audit-orphan-pv.sh"
  [ "$status" -eq 4 ]
  echo "$output" | grep -q "^SKIP: audit-orphan-pv:"
  out="$output"
  run grep -q "^SCAN:" <<<"$out"
  [ "$status" -ne 0 ]
}

@test "a retired ORPHAN_PVC env floor is inert and --floor is the only override (vocabulary witness)" {
  # 폐지 env가 되살아나도 skip 경로 앞에서는 관측 불가지만, 오타 키 fail-closed는 라이브 무관하게
  # 파싱 시점에 검증된다 — 어휘 증인으로 이 축을 못박는다.
  run bash "$ROOT/scripts/audit-orphan-pv.sh" --floor bogus=1
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "조용히 꺼진 바닥값"
}
