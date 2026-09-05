#!/usr/bin/env bats
# netpol-rehearsal.sh(owner-local, 라이브 변이) 정적 안전 불변식 — 라이브 실행 없이.
# ⚠️ 비평가 실증(감사 9라운드 72, critic-netpol-rehearsal-identity): scripts/reset-pg-r2-archive.sh:27과
#    동형인 클러스터 정체성 프리플라이트(:15의 assert-cluster-identity.sh 직접 호출)에 도메인 bats
#    증인이 0건이었다 — `git grep -l assert-cluster-identity scripts infra`가 찾는 유일한 소비처
#    (tests/posture/test_network-policy.bats:40)는 산문 언급뿐이고, 그 파일 자체도
#    tests/.ci-exclude(라이브 전용, 라인 30)라 required gate 밖이다. tests/gates/test_make-ops-targets.bats는
#    Makefile 경유 타깃(argo-sync/argo-terminate/bootstrap)만 다뤄 이 직접 실행 스크립트는 범위 밖이다.
sh=scripts/netpol-rehearsal.sh

@test "netpol-rehearsal exists, is executable, and passes shellcheck" {
  [ -x "$sh" ]
  run shellcheck "$sh"
  [ "$status" -eq 0 ]
}

@test "netpol-rehearsal calls the D-i cluster identity preflight before installing the restore trap" {
  # ⚠️ 헤더(:11-14)가 "trap을 걸기 **전에** 정체성부터 확인한다"고 선언하는 그 호출이다 — 삭제해도
  #    (2026-09 뮤테이션 실측) 이 파일을 참조하는 유일한 bats(위 주석, 라이브 전용)가 못 잡는다.
  grep -qE '^bash ".*assert-cluster-identity\.sh"$' "$sh"
  # 배치 — 정체성 확인이 restore trap 설치(잘못된 클러스터에 걸리면 안 되는 그 trap)보다 앞이어야 한다.
  # 관용구: tests/gates/test_make-ops-targets.bats:73-76(순서-비교, 두 grep -n을 -lt로 대조).
  a="$(grep -n 'assert-cluster-identity\.sh' "$sh" | head -1 | cut -d: -f1)"
  t="$(grep -n '^trap restore EXIT$' "$sh" | head -1 | cut -d: -f1)"
  [ -n "$a" ] && [ -n "$t" ] && [ "$a" -lt "$t" ]
}
