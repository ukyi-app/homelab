#!/usr/bin/env bats
# reusable-app-build.yaml cross-repo 계약 가드. deploy-trigger를 앱 release.yaml에서 흡수(B11) —
# 앱 caller는 영구 thin-caller(uses + with.app + dispatch secret 2개 passthrough)로 축소된다.
# ⚠️ 중간 부정 단언은 run+[ ]만(bash3.2 침묵 통과 함정). yq는 CI/로컬 버전차 방어적 추출.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; F="$ROOT/.github/workflows/reusable-app-build.yaml"; }

@test "reusable-app-build: workflow_call build stage present (arm64 GHCR push)" {
  grep -q 'workflow_call' "$F"
  grep -q 'linux/arm64' "$F"
}

@test "reusable-app-build: v1 dispatch path stays retired (no repository_dispatch / dispatch-pat / environment)" {
  run grep -E "repos/.*/dispatches|app-onboard|app-image|environment: production" "$F"
  [ "$status" -ne 0 ]
  run grep -q 'dispatch-pat' "$F"
  [ "$status" -ne 0 ]
}

@test "reusable-app-build: inputs contract is exactly [app] with app required" {
  command -v yq >/dev/null || skip "yq required"
  [ "$(yq -r '.on.workflow_call.inputs.app.required // "null"' "$F")" = "true" ]
  keys="$(yq -o=json -r '.on.workflow_call.inputs | keys' "$F" | jq -c 'sort')"
  [ "$keys" = '["app"]' ]
}

@test "reusable-app-build: absorbed deploy-trigger declares exactly 2 optional dispatch secrets (per-repo, no org secret)" {
  command -v yq >/dev/null || skip "yq required"
  # ⚠️ yq의 `//`는 false도 empty로 취급(false // "null" = "null") — 부재 판별엔 못 쓴다. 직접 값 비교.
  [ "$(yq -r '.on.workflow_call.secrets.HOMELAB_DISPATCH_APP_ID.required' "$F")" = "false" ]
  [ "$(yq -r '.on.workflow_call.secrets.HOMELAB_DISPATCH_APP_PRIVATE_KEY.required' "$F")" = "false" ]
  skeys="$(yq -o=json -r '.on.workflow_call.secrets | keys' "$F" | jq -c 'sort')"
  [ "$skeys" = '["HOMELAB_DISPATCH_APP_ID","HOMELAB_DISPATCH_APP_PRIVATE_KEY"]' ]
}

@test "reusable-app-build: deploy-trigger job absorbed (needs build + preflight-skip + App token + bump-poll dispatch)" {
  command -v yq >/dev/null || skip "yq required"
  [ "$(yq -r '.jobs.deploy-trigger.needs // "null"' "$F")" = "build" ]
  grep -q 'create-github-app-token' "$F"
  grep -q 'gh workflow run bump-poll.yaml' "$F"
  grep -q 'configured=false' "$F"   # 시크릿 부재 시 clean skip(preflight)
}
