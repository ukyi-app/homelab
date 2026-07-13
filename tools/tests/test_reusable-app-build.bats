#!/usr/bin/env bats
# reusable-app-build.yaml cross-repo 계약 가드. deploy-trigger를 앱 release.yaml에서 흡수(B11) —
# 앱 caller는 영구 thin-caller(uses + with.app + dispatch secret 2개 passthrough)로 축소된다.
# 모드는 둘: release caller(push 기본 true = 오늘 동작) / PR caller(push: false = BUILD ONLY, Dockerfile 품질
# 게이트만 돌리고 GHCR·배포는 안 건드림). 아래 가드가 그 두 모드의 배선과 하위호환(기본값 true)을 못 박는다.
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

@test "reusable-app-build: inputs contract is exactly [app, push] (app required; push boolean default true)" {
  command -v yq >/dev/null || skip "yq required"
  [ "$(yq -r '.on.workflow_call.inputs.app.required // "null"' "$F")" = "true" ]
  keys="$(yq -o=json -r '.on.workflow_call.inputs | keys' "$F" | jq -c 'sort')"
  [ "$keys" = '["app","push"]' ]
  # push의 기본값이 true라야 기존 caller(release.yaml: with.app만 전달)의 동작이 그대로다 — 이 줄이 그 하위호환 계약.
  # ⚠️ yq `//`는 false를 empty로 삼키므로 부재 판별엔 못 쓴다(아래 secrets 주석과 동일 함정) — 직접 값 비교.
  [ "$(yq -r '.on.workflow_call.inputs.push.type' "$F")" = "boolean" ]
  [ "$(yq -r '.on.workflow_call.inputs.push.default' "$F")" = "true" ]
}

@test "reusable-app-build: build-only mode is honest (push input wired; login+deploy-trigger gated on it)" {
  command -v yq >/dev/null || skip "yq required"
  # push=false = BUILD ONLY. 세 배선이 전부 있어야 정직하다 — 하나라도 빠지면 PR 빌드가 밀거나(레지스트리 오염)
  # 밀지도 않은 이미지로 배포를 깨운다.
  build_push="$(yq -r '.jobs.build.steps[] | select(.uses | test("docker/build-push-action")) | .with.push' "$F")"
  [ "$build_push" = '${{ inputs.push }}' ]
  login_if="$(yq -r '.jobs.build.steps[] | select(.uses | test("docker/login-action")) | .if' "$F")"
  [ "$login_if" = '${{ inputs.push }}' ]   # GHCR 로그인은 push 경로 전용(build-only 토큰엔 packages 스코프도 없다)
  [ "$(yq -r '.jobs.deploy-trigger.if' "$F")" = '${{ inputs.push }}' ]
}

@test "reusable-app-build: build job declares no permissions (caller sets the ceiling = build-only least privilege)" {
  command -v yq >/dev/null || skip "yq required"
  # ★약화 금지. 여기에 packages: write를 박는 순간 build-only caller(PR 워크플로 = contents: read만 준다)는
  #   startup_failure로 죽는다("nested job is requesting 'packages: write', but is only allowed 'packages: none'").
  #   permissions 키는 표현식 불가라 모드별 분기가 없다 → 상한 결정을 caller에 위임하는 게 유일한 정직한 배선이다:
  #   push=true caller는 packages: write를 주고(기존 release.yaml 그대로), PR caller는 안 준다 → 밀고 싶어도 못 민다.
  [ "$(yq -r '.jobs.build.permissions // "absent"' "$F")" = "absent" ]
  [ "$(yq -r '.jobs.deploy-trigger.permissions | length' "$F")" = "0" ]   # deploy-trigger는 자체 App 토큰만 씀(권한 0)
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
