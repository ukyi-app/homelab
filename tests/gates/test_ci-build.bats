#!/usr/bin/env bats
WF=".github/workflows/build.yaml"

@test "build job runs on ubuntu-24.04-arm (native arm64, no QEMU)" {
  run yq '.jobs.build.runs-on' "$WF"
  [[ "$output" == "ubuntu-24.04-arm" ]]
  run grep -i "setup-qemu" "$WF"
  [ "$status" -ne 0 ] # QEMU를 쓰면 안 된다
}

@test "build pushes immutable :sha-<gitsha> to GHCR" {
  run grep -E "ghcr.io/.*:sha-" "$WF"
  [ "$status" -eq 0 ]
  run yq '.jobs.build.steps[] | select(.uses | test("build-push-action")) | .with.platforms' "$WF"
  [[ "$output" == *"linux/arm64"* ]]
}

@test "matrix builds only the platform ops image pg-tools (no in-repo apps)" {
  run yq '.jobs.build.strategy.matrix.app' "$WF"
  [[ "$output" == *"pg-tools"* ]]
  [[ "$output" != *"api"* ]] # 사용자 앱은 외부 레포에서 빌드 — homelab matrix엔 없음
  run grep -E "pg-tools:16-rclone" "$WF"
  [ "$status" -eq 0 ]
}
