#!/usr/bin/env bats
# 스키마 fail-closed 회귀 (additionalProperties:false + 전수등재 + extraManifests 제거)
# ⚠️ 이 파일에서 `-eq 1`로 전환한 부재 단언은 **경로 피연산자를 든 grep 하나뿐**이다(맨 아래).
#    나머지 `-ne 0`은 전부 `run helm template`이라 rc가 helm의 규약이고, 부재할 경로 피연산자가 없다.
CHART="${BATS_TEST_DIRNAME}/.."
C="--set image.repo=ghcr.io/o/x --set image.tag=sha-abc1234 \
   --set resources.requests.cpu=10m --set resources.requests.memory=32Mi \
   --set resources.limits.cpu=100m --set resources.limits.memory=64Mi \
   --set route.public=true --set route.host=x.example.com"

@test "schema rejects an unknown top-level key (typo'd security/probe keys cannot pass silently)" {
  run helm template t "$CHART" $C --set kind=web --set securtyContext.foo=bar
  [ "$status" -ne 0 ]
}

@test "schema rejects extraManifests (removed; extra manifests go via kustomize source#3)" {
  run helm template t "$CHART" $C --set kind=web --set 'extraManifests[0].kind=Pod'
  [ "$status" -ne 0 ]
}

@test "schema rejects mutable image tags (immutable sha pin only)" {
  run helm template t "$CHART" --set image.repo=ghcr.io/o/x --set image.tag=latest \
    --set resources.requests.cpu=10m --set resources.requests.memory=32Mi \
    --set resources.limits.cpu=100m --set resources.limits.memory=64Mi \
    --set route.public=true --set route.host=x.example.com --set kind=web
  [ "$status" -ne 0 ]
  # ⚠️ 상한 — 위 단언은 `latest` 한 값의 rc만 본다. 패턴에 `v[0-9]+` 같은 대안을 더해도 `latest`는
  #    여전히 red라 이 줄만으로는 완화가 무증인이었다(실측: 패턴 확장 후 이 파일 60/60 ok 유지).
  #    이 자리는 손편집 방어의 2차선이다 — 자동 writer는 create-app.ts:45/bump-tag.ts:80의
  #    TAG_RE·scripts/check-image-pins.sh 레인2(b)의 digest 필수 검사가 이미 1차선을 막는다.
  #    후행 --set이 $C의 image.tag=sha-abc1234를 이긴다(helm 규약).
  run helm template t "$CHART" $C --set kind=web --set image.tag=v1
  [ "$status" -ne 0 ]   # latest 이외의 가변 태그도 거부(패턴에 대안 추가 시 red)
}

@test "schema rejects a custom ports.http (const 8080 — coupled to prod ns-wide NetworkPolicy)" {
  run helm template t "$CHART" $C --set kind=web --set ports.http=3000
  [ "$status" -ne 0 ]
}

@test "schema rejects a custom ports.metrics (const 9090 — coupled to prod ns-wide NetworkPolicy)" {
  run helm template t "$CHART" $C --set kind=web --set ports.metrics=3000
  [ "$status" -ne 0 ]
}

@test "schema rejects nameOverride (app name is selector-derived; Deployment.spec.selector is immutable)" {
  run helm template t "$CHART" $C --set kind=web --set nameOverride=renamed
  [ "$status" -ne 0 ]
}

@test "schema rejects securityContext.privileged=true" {
  run helm template t "$CHART" $C --set kind=web --set securityContext.privileged=true
  [ "$status" -ne 0 ]
}

@test "schema rejects securityContext.allowPrivilegeEscalation=true" {
  run helm template t "$CHART" $C --set kind=web --set securityContext.allowPrivilegeEscalation=true
  [ "$status" -ne 0 ]
}

@test "schema rejects podSecurityContext.runAsNonRoot=false" {
  run helm template t "$CHART" $C --set kind=web --set podSecurityContext.runAsNonRoot=false
  [ "$status" -ne 0 ]
}

@test "schema rejects runAsUser=0 (root) in pod or container security context" {
  run helm template t "$CHART" $C --set kind=web --set podSecurityContext.runAsUser=0
  [ "$status" -ne 0 ]
  run helm template t "$CHART" $C --set kind=web --set securityContext.runAsUser=0
  [ "$status" -ne 0 ]
}

@test "all three fixtures still render under the tightened schema (behavior-preserving)" {
  for k in web worker site; do
    run helm template t "$CHART" -f "$CHART/tests/fixtures/$k.yaml"
    [ "$status" -eq 0 ]
  done
}

@test "deployment template no longer emits an extraManifests range block" {
  # 양성 대조 — 그 템플릿이 아직 Deployment를 렌더하는 파일인지. 통째로 비면 grep은 rc 1이라
  # 아래 부재 단언 혼자서는 못 잡는다(격리 트리 실측: 0바이트로 비워도 ok였다).
  run grep -q "kind: Deployment" "$CHART/templates/deployment.yaml"
  [ "$status" -eq 0 ]
  # 부재는 `-eq 1` — 리네임/삭제의 rc 2를 "extraManifests 없음"으로 읽지 않는다
  # (실측: deployment.yaml을 리네임해도 이 @test는 홀로 초록이었다).
  # cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③·③-a
  run grep -q "extraManifests" "$CHART/templates/deployment.yaml"
  [ "$status" -eq 1 ]
}
