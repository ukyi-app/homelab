#!/usr/bin/env bats
# reusable-app-build.yaml 외부 cross-repo 계약 가드(test_onboard.bats에서 이관 — v1 폐기).
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; }

@test "reusable-app-build v1: build-only, dispatch jobs gone, dispatch-pat optional-compat" {
  f="$ROOT/.github/workflows/reusable-app-build.yaml"
  grep -q 'workflow_call' "$f"
  grep -q 'linux/arm64' "$f"
  run grep -E "repos/.*/dispatches|app-onboard|app-image|environment: production" "$f"
  [ "$status" -ne 0 ]
  grep -q 'dispatch-pat' "$f"
  # 구조 검사(C-F4·C-F7): dispatch-pat과 required 사이에 description 줄이 끼어 grep -A1 인접성이 깨진다.
  # yq로 required==false 직접 확인(yq는 GHA on: 키를 문자열로 정상 파싱 — on→true 함정 없음, 실측 확인).
  command -v yq >/dev/null || skip "yq required"
  [ "$(yq -r '.on.workflow_call.secrets.dispatch-pat.required' "$f")" = "false" ]
}
