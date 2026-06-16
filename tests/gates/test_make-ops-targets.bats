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
  run grep -A4 '^verify-posture:' Makefile
  echo "$output" | grep -q 'KUBECONFIG'   # 라이브 가드
  echo "$output" | grep -q 'tests/posture'
}
