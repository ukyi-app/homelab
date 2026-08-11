#!/usr/bin/env bats
# reusable-app-build.yaml cross-repo 계약 가드. deploy-trigger를 앱 release.yaml에서 흡수(B11) —
# 앱 caller는 영구 thin-caller(uses + with.app + dispatch secret 2개 passthrough)로 축소된다.
# 모드는 둘: release caller(push 기본 true = 오늘 동작) / PR caller(push: false = BUILD ONLY, Dockerfile 품질
# 게이트만 돌리고 GHCR·배포는 안 건드림). 아래 가드가 그 두 모드의 배선과 하위호환(기본값 true)을 못 박는다.
# ⚠️ 중간 부정 단언은 run+[ ]만(bash3.2 침묵 통과 함정). yq는 CI/로컬 버전차 방어적 추출.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; F="$ROOT/.github/workflows/reusable-app-build.yaml"; }

@test "reusable-app-build: workflow_call build stage present (multi-arch GHCR push)" {
  grep -q 'workflow_call' "$F"
  command -v yq >/dev/null || skip "yq required"
  # NUC(amd64) 이전 — 한쪽만 남으면 그 노드에서 앱이 못 돈다. 이전엔 arm64만 단언했다.
  # ⚠️ 파일 전체 grep을 쓰지 않는다 — 측정 근거를 적은 **주석**에 같은 문자열이 있어
  #   platforms 값을 지워도 통과한다(자체 뮤테이션으로 실측). .with.platforms 값만 본다.
  # ⚠️ `[[ ]]`를 쓰지 않는다 — bats는 [[ 실패를 errexit 면제로 **침묵 통과**시켜(이 파일 헤더 :6,
  #   scripts/check-bats-style.sh:3) 마지막 문장이 아닌 단언이 무력화된다. 자체 뮤테이션에서
  #   amd64를 지웠는데 초록이 나와 실측 확인했다. 평범한 명령(grep)이라야 errexit이 잡는다.
  run yq '.jobs.build.steps[] | select(.uses | test("build-push-action")) | .with.platforms' "$F"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q "linux/amd64"
  printf '%s' "$output" | grep -q "linux/arm64"
}

@test "reusable-app-build: setup-qemu present and before setup-buildx" {
  command -v yq >/dev/null || skip "yq required"
  # buildx 빌더는 **생성 시점**에 등록된 binfmt 핸들러만 본다. 뒤집히면 amd64 leg가
  # 'exec format error'로 죽고 그 실패는 빌드 로그 깊숙이에서만 보인다.
  # ⚠️ grep -n 줄번호 비교는 쓰지 않는다 — 이 함정을 설명하는 주석이 먼저 잡혀 공허해진다
  #   (build.yaml 게이트에서 자체 뮤테이션으로 실측). steps[].uses 인덱스로 구조 비교한다.
  q="$(yq '[.jobs.build.steps[].uses // ""] | to_entries | map(select(.value|test("setup-qemu"))) | .[0].key // "null"' "$F")"
  b="$(yq '[.jobs.build.steps[].uses // ""] | to_entries | map(select(.value|test("setup-buildx"))) | .[0].key // "null"' "$F")"
  [ "$q" != "null" ]
  [ "$b" != "null" ]
  [ "$q" -lt "$b" ]
}

@test "reusable-app-build: provenance false — index digest must be deterministic" {
  command -v yq >/dev/null || skip "yq required"
  # attestation이 켜지면 인덱스에 unknown/unknown 자식이 붙고 그 매니페스트가 run마다 달라져
  # 인덱스 digest가 비결정적이 된다(실측: provenance=false 2회 468db06f… 동일 / 기본값 2회 상이).
  # 그러면 tools/poll-ghcr.ts computeBump의 멱등 no-op이 영영 안 걸려 Docker 컨텍스트 밖 커밋마다
  # PR·머지·롤아웃이 헛돈다. 이 파일은 cross-repo 공개 계약이라 되돌리면 3개 앱 레포에 동시 파급된다.
  run yq '.jobs.build.steps[] | select(.uses | test("build-push-action")) | .with.provenance' "$F"
  [ "$output" = "false" ]
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
