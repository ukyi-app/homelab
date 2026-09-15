#!/usr/bin/env bats
# 실제 workflow의 셸 본문으로 owner·ref·revision과 공개 표식 경계를 검사한다.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  WF="$ROOT/.github/workflows/ci-authority-probe.yaml"
  BODY="$(yq -r '.jobs.authorize.steps[0].run' "$WF")"
  PROBE="$(yq -r '.jobs.protected-environment.steps[0].run' "$WF")"
  SHA=1111111111111111111111111111111111111111
}

origin() {
  env OWNER=Alice ACTOR=ALICE TRIGGERING=aLiCe REPOSITORY_ID=1265054638 \
    EVENT=workflow_dispatch ATTEMPT=1 REF=refs/heads/main REF_TYPE=branch \
    WORKFLOW_REF=ukyi-app/homelab/.github/workflows/ci-authority-probe.yaml@refs/heads/main \
    WORKFLOW_SHA="$SHA" EVENT_SHA="$SHA" REVIEWED="$SHA" "$@" bash -e -c "$BODY"
}

@test "authority probe is manual and has no token permission or checkout" {
  run bun -e '
    const fs=require("node:fs"),y=require("yaml"),s=fs.readFileSync(process.argv[1],"utf8"),d=y.parse(s);
    if (JSON.stringify(Object.keys(d.on))!==JSON.stringify(["workflow_dispatch"])) process.exit(1);
    if (JSON.stringify(d.permissions)!=="{}") process.exit(1);
    if (Object.keys(d.jobs).sort().join(",")!=="authorize,protected-environment") process.exit(1);
    for (const job of Object.values(d.jobs)) {
      if (job.permissions || job.steps.some(step=>step.uses)) process.exit(1);
    }
    if (d.jobs["protected-environment"].needs!=="authorize" || d.jobs["protected-environment"].environment!=="homelab-main") process.exit(1);
    const names=[...s.matchAll(/secrets\.([A-Z_0-9]+)/g)].map(x=>x[1]);
    if (JSON.stringify(names)!==JSON.stringify(["AIOPS_CI_PUBLIC_CANARY_0915"])) process.exit(1);
  ' "$WF"
  [ "$status" -eq 0 ]
}

@test "authority probe accepts owner case normalization at the reviewed main SHA" {
  run origin
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -F '"originVerified": true'
}

@test "authority probe rejects absent owner foreign actor and foreign triggering actor" {
  local assignment
  for assignment in OWNER= ACTOR=mallory TRIGGERING=mallory; do
    run origin "$assignment"
    [ "$status" -eq 1 ]
    printf '%s' "$output" | grep -E 'HOMELAB_OWNER 미설정|workflow_dispatch는 owner'
  done
}

@test "authority probe rejects a replay or another event or repository" {
  local assignment
  for assignment in ATTEMPT=2 EVENT=pull_request REPOSITORY_ID=7; do
    run origin "$assignment"
    [ "$status" -eq 1 ]
    printf '%s' "$output" | grep -F 'authority-probe-origin-invalid'
  done
}

@test "authority probe rejects moved source and unreviewed SHA" {
  local assignment
  for assignment in WORKFLOW_SHA=2222222222222222222222222222222222222222 REVIEWED=bad EVENT_SHA=2222222222222222222222222222222222222222; do
    run origin "$assignment"
    [ "$status" -eq 1 ]
    printf '%s' "$output" | grep -F 'authority-probe-revision-invalid'
  done
}

@test "authority probe permits same-name tag to reach the server environment policy" {
  run origin REF=refs/tags/main REF_TYPE=tag \
    WORKFLOW_REF=ukyi-app/homelab/.github/workflows/ci-authority-probe.yaml@refs/tags/main
  [ "$status" -eq 0 ]
  run origin REF=refs/heads/aiops/test
  [ "$status" -eq 1 ]
  printf '%s' "$output" | grep -F 'authority-probe-ref-invalid'
}

@test "authority probe rejects a different workflow source" {
  run origin WORKFLOW_REF=ukyi-app/homelab/.github/workflows/other.yaml@refs/heads/main
  [ "$status" -eq 1 ]
  printf '%s' "$output" | grep -F 'authority-probe-workflow-invalid'
}

@test "main environment probe requires exact public marker and never prints its value" {
  run env REF=refs/heads/main REF_TYPE=branch PUBLIC_CANARY=AIOPS-CI-AUTHORITY-20260915-public-marker bash -e -c "$PROBE"
  [ "$status" -eq 0 ]
  [ "$output" = '{"protectedEnvironmentReached": true, "publicMarkerMatched": true, "mainBranch": true}' ]
  run env REF=refs/heads/main REF_TYPE=branch PUBLIC_CANARY= bash -e -c "$PROBE"
  [ "$status" -eq 1 ]
  [ "$output" = '{"protectedEnvironmentReached": true, "publicMarkerMatched": false, "mainBranch": true}' ]
  run env REF=refs/heads/main REF_TYPE=branch PUBLIC_CANARY=unexpected-private-looking-value bash -e -c "$PROBE"
  [ "$status" -eq 1 ]
  [ "$output" = '{"protectedEnvironmentReached": true, "publicMarkerMatched": false, "mainBranch": true}' ]
}

@test "an executing tag probe fails even if the environment marker matches" {
  run env REF=refs/tags/main REF_TYPE=tag PUBLIC_CANARY=AIOPS-CI-AUTHORITY-20260915-public-marker bash -e -c "$PROBE"
  [ "$status" -eq 1 ]
  [ "$output" = '{"protectedEnvironmentReached": true, "publicMarkerMatched": true, "mainBranch": false}' ]
}
