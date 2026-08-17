#!/usr/bin/env bats
# 운영 make 진입점 — AGENTS.md 산문에만 있던 argo patch/kustomize 풀렌더를 타겟화.
# dry-run(make -n)으로 명령 구성만 검사(라이브 클러스터 불필요). read-only 전제.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "argo-sync composes an explicit-sync patch for the given APP" {
  run make -n argo-sync APP=cnpg
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "patch app cnpg"
  echo "$output" | grep -q "operation"
}

@test "argo-status lists applications with sync/health/operation columns" {
  run make -n argo-status
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "applications"
  echo "$output" | grep -q "operationState"
}

@test "argo and render targets point at the live kubeconfig / KSOPS flags" {
  run make -n argo-status
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "infra/k3s-bootstrap/kubeconfig"
  run make -n render COMP=cnpg
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "kustomize build"
  echo "$output" | grep -q "enable-exec"
  echo "$output" | grep -q "platform/cnpg/prod"
}

@test "render refuses to run without COMP" {
  run make render
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "COMP"
}

@test "make verify-posture target exists and is live-guarded" {
  run grep -E '^verify-posture:' Makefile
  [ "$status" -eq 0 ]
  # 원문 grep이 아니라 `make -n` — 대상 스위트가 POSTURE_BATS 시임으로 빠져 원문엔 리터럴이 없다.
  # 해소된 recipe를 보는 쪽이 실제 행동에 더 가깝다.
  run make -n verify-posture
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'KUBECONFIG'   # 라이브 가드
  echo "$output" | grep -q 'tests/posture'
}

# ── D-i(2026-08-12) 클러스터 정체성 프리플라이트 ──────────────────────────────────────────
# ⚠️ 라이브 Mac과 NUC의 kubeconfig는 경로·포트·노드명이 같다. 잘못된 KUBECONFIG로 변이 명령을
#    쏘면 아무 경고 없이 반대편을 때린다. 아래 두 @test가 그 프리플라이트의 **존재와 강도**를
#    고정한다 — 주입이 조용히 사라지면 red다.
# ⚠️ prerequisite가 아니라 recipe 줄이어야 한다(test_guard-skip-signalling이 make verify-posture를
#    실제로 실행하므로 prerequisite는 그 @test들을 죽인다). make -n 이 recipe 줄을 보여주므로
#    아래 검사는 그 배치까지 함께 고정한다.

@test "mutating ops targets assert cluster identity before touching the cluster" {
  bad=""
  for t in argo-sync argo-terminate; do
    run make -n "$t" APP=cnpg
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'assert-cluster-identity.sh' || bad="$bad $t"
    # 변이 경로는 warn이 아니라 fail-closed여야 한다.
    echo "$output" | grep -q 'assert-cluster-identity.sh --warn' && bad="$bad $t(warn)"
  done
  run make -n bootstrap
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'assert-cluster-identity.sh' || bad="$bad bootstrap"
  [ -z "$bad" ]   # 비어야 통과. 디버깅: echo "$bad"
}

@test "read-only ops targets warn instead of blocking (3am observability stays reachable)" {
  bad=""
  for t in argo-status audit-orphan-pv; do
    run make -n "$t"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'assert-cluster-identity.sh --warn' || bad="$bad $t"
  done
  [ -z "$bad" ]
}
