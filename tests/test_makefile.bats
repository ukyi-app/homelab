#!/usr/bin/env bats

@test "just verify runs the foundation checks and passes" {
  run just verify
  [ "$status" -eq 0 ]
}

@test "the deliberately-unwired down target still exits non-zero and names the primitive" {
  # `down`은 이제 '미구현'이 아니라 **의도적 비배선**이다: 파괴 프리미티브는 scripts/destroy-node.sh이고
  # just에 배선하지 않는다(파괴 스크립트는 owner가 직접 실행한다).
  # ⚠️ 이 @test는 `just down`을 **실제로 실행한다** — 그래서 배선하지 않는 것이 결정의 일부다.
  #    배선하면 이 줄이 owner 머신(=라이브 NUC)에서 파괴 스크립트를 부르게 된다.
  run just down
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- 'scripts/destroy-node.sh'
}

@test "bootstrap delegates to scripts/bootstrap.sh (dry-run)" {
  run just --dry-run bootstrap
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'scripts/bootstrap.sh'
}

@test "just help lists every declared target" {
  run just help
  [ "$status" -eq 0 ]
  for t in bootstrap up down verify host-up; do
    echo "$output" | grep -q "$t"
  done
}

@test "up delegates to the host-substrate orchestrator (dry-run shows host-up.sh)" {
  run just --dry-run up
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'infra/k3s-bootstrap/host-up.sh'
}

@test "host-up delegates to the host-substrate orchestrator (dry-run shows host-up.sh)" {
  run just --dry-run host-up
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'infra/k3s-bootstrap/host-up.sh'
}

@test "just verify-ksops wires the four KSOPS bats and gates on the age key" {
  run just --dry-run verify-ksops
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'test_ksops_render.bats'
  echo "$output" | grep -q 'test_kustomize_build.bats'
  echo "$output" | grep -q 'SOPS_AGE_KEY_FILE'
}
