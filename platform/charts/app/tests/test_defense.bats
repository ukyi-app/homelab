#!/usr/bin/env bats
CHART="${BATS_TEST_DIRNAME}/.."
dep() { helm template t "$CHART" --set image.repo=ghcr.io/o/x --set image.tag=sha-abc1234 \
  --set resources.requests.cpu=10m --set resources.requests.memory=32Mi \
  --set resources.limits.cpu=100m --set resources.limits.memory=64Mi "$@" | yq 'select(.kind=="Deployment")'; }

@test "pods do not automount the ServiceAccount token by default (apps need no k8s API)" {
  out=$(dep --set kind=worker)
  echo "$out" | grep -q 'automountServiceAccountToken: false'
}

@test "automountServiceAccountToken can be opted in for API-using apps" {
  out=$(dep --set kind=worker --set automountServiceAccountToken=true)
  echo "$out" | grep -q 'automountServiceAccountToken: true'
}

@test "migration Job pod also defaults to no SA token automount (Pass2 #1: second pod template)" {
  # db.enabled면 migrate-job.yaml이 앱 이미지+envFrom 시크릿으로 Job 파드를 렌더한다 — 별도 파드 spec이라
  # deployment fix가 안 닿는다. Job 파드도 토큰 미마운트여야 공격표면이 진짜 닫힌다.
  out=$(helm template t "$CHART" --set image.repo=ghcr.io/o/x --set image.tag=sha-abc1234 \
    --set resources.requests.cpu=10m --set resources.requests.memory=32Mi \
    --set resources.limits.cpu=100m --set resources.limits.memory=64Mi \
    --set kind=service --set route.host=a.example.com --set db.enabled=true | yq 'select(.kind=="Job")')
  echo "$out" | grep -q 'automountServiceAccountToken: false'
}

@test "migration Job honors automount opt-in too" {
  out=$(helm template t "$CHART" --set image.repo=ghcr.io/o/x --set image.tag=sha-abc1234 \
    --set resources.requests.cpu=10m --set resources.requests.memory=32Mi \
    --set resources.limits.cpu=100m --set resources.limits.memory=64Mi \
    --set kind=service --set route.host=a.example.com --set db.enabled=true \
    --set automountServiceAccountToken=true | yq 'select(.kind=="Job")')
  echo "$out" | grep -q 'automountServiceAccountToken: true'
}

@test "Deployment strategy defaults to Recreate (single-node RWO deadlock safety)" {
  out=$(dep --set kind=service --set route.host=a.example.com)
  echo "$out" | grep -q 'type: Recreate'
}

@test "strategy can be overridden to RollingUpdate for multi-replica stateless apps" {
  out=$(dep --set kind=service --set route.host=a.example.com --set strategy.type=RollingUpdate)
  echo "$out" | grep -q 'type: RollingUpdate'
}
