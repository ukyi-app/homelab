#!/usr/bin/env bats
CHART="${BATS_TEST_DIRNAME}/.."
# 형식만 유효한 64-hex digest 픽스처 (실제 이미지와 무관)
DIG="sha256:4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945"
# db.enabled=true로 Deployment + migration Job을 모두 렌더해 이미지 일치를 검증한다
BASE="--set image.repo=ghcr.io/o/api --set kind=service \
  --set route.host=api.example.com --set db.enabled=true \
  --set resources.requests.cpu=50m --set resources.requests.memory=64Mi \
  --set resources.limits.cpu=500m --set resources.limits.memory=128Mi"

# 주의: 이 머신의 bats는 bash 3.2에서 돌므로 중간 assertion은 반드시 단순 명령 `[ ]`로.
# `[[ ]]`는 compound command라 bash 3.2의 set -e가 무시한다 — 중간 실패가 조용히 통과한다.
dep_image() { yq 'select(.kind=="Deployment") | .spec.template.spec.containers[0].image' <<<"$1"; }
job_image() { yq 'select(.kind=="Job") | .spec.template.spec.containers[0].image' <<<"$1"; }

@test "deployment and migrate job render the same repo@digest when image.digest is set" {
  out=$(helm template t "$CHART" $BASE --set image.tag=sha-abc1234 --set image.digest="$DIG")
  dep=$(dep_image "$out")
  job=$(job_image "$out")
  # digest가 tag보다 우선한다 — 둘 다 동일한 불변 참조여야 한다 (skew 방지의 핵심)
  [ "$dep" == "ghcr.io/o/api@$DIG" ]
  [ "$job" == "$dep" ]
}

@test "deployment and migrate job render the same repo:tag when image.digest is unset" {
  out=$(helm template t "$CHART" $BASE --set image.tag=sha-abc1234)
  dep=$(dep_image "$out")
  job=$(job_image "$out")
  [ "$dep" == "ghcr.io/o/api:sha-abc1234" ]
  [ "$job" == "$dep" ]
}

@test "tag is optional when digest is set (schema contract)" {
  # tag 미지정(기본 "") + digest만으로 렌더가 성공해야 한다
  out=$(helm template t "$CHART" $BASE --set image.digest="$DIG")
  dep=$(dep_image "$out")
  [ "$dep" == "ghcr.io/o/api@$DIG" ]
}

@test "schema rejects a malformed image.digest" {
  run helm template t "$CHART" $BASE --set image.tag=sha-abc1234 --set image.digest=sha256:nothex
  [ "$status" -ne 0 ]
  [[ "$output" == *"digest"* ]]
}
