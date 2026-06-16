#!/usr/bin/env bats
# bats가 동작하고 helper가 로드됨을 증명하는 스모크 테스트.

load test_helper

@test "bats harness loads and BOOTSTRAP_DIR resolves" {
  [ -d "$BOOTSTRAP_DIR" ]
  [ -f "$BOOTSTRAP_DIR/.gitignore" ]
}

@test "kubeconfig path is gitignored" {
  run grep -qx 'kubeconfig' "$BOOTSTRAP_DIR/.gitignore"
  [ "$status" -eq 0 ]
}
