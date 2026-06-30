#!/usr/bin/env bats
# reusable-app-build.yaml 외부 cross-repo 계약 가드(test_onboard.bats에서 이관 — v1 dispatch 폐기 완료).
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; }

@test "reusable-app-build: build-only, dispatch jobs + dispatch-pat fully removed (v1 retired)" {
  f="$ROOT/.github/workflows/reusable-app-build.yaml"
  grep -q 'workflow_call' "$f"
  grep -q 'linux/arm64' "$f"
  run grep -E "repos/.*/dispatches|app-onboard|app-image|environment: production" "$f"
  [ "$status" -ne 0 ]
  # v1 dispatch 경로 완전 폐기: dispatch-pat 입력과 secrets 블록이 제거되어야 한다.
  run grep -q 'dispatch-pat' "$f"
  [ "$status" -ne 0 ]
  command -v yq >/dev/null || skip "yq required"
  [ "$(yq -r '.on.workflow_call.secrets // "null"' "$f")" = "null" ]
}
