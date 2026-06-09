#!/usr/bin/env bats
# Smoke test that proves bats runs and the helper loads.

load test_helper

@test "bats harness loads and BOOTSTRAP_DIR resolves" {
  [ -d "$BOOTSTRAP_DIR" ]
  [ -f "$BOOTSTRAP_DIR/.gitignore" ]
}

@test "kubeconfig path is gitignored" {
  run grep -qx 'kubeconfig' "$BOOTSTRAP_DIR/.gitignore"
  [ "$status" -eq 0 ]
}
