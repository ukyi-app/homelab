#!/usr/bin/env bats
# 상주 워크로드 memory limit 가드 (vector OOM PR #85 포스트모템). @test 이름은 영어(CJK 인코딩 함정).
# CI-safe(소스 매니페스트 yq/python 스캔, 라이브/age/docker 불요) → run-bats.sh gate 도메인에 자동 수집.

@test "all resident workload containers declare a memory limit (or are allowlisted)" {
  run bash "${BATS_TEST_DIRNAME}/../scripts/check-memory-limits.sh"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "memory-limit guard fails on a workload missing a limit (red-green)" {
  # 실제 스크립트를 임시 트리(위반 매니페스트 1건)에 복사 실행해 가드가 정말 잡는지 증명.
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/scripts" "$tmp/platform/probe/prod" "$tmp/policy"
  cp "${BATS_TEST_DIRNAME}/../scripts/check-memory-limits.sh" "$tmp/scripts/"
  : > "$tmp/policy/memory-limit-allowlist.txt"
  cat > "$tmp/platform/probe/prod/deploy.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata: { name: probe, namespace: probe }
spec:
  template:
    spec:
      containers:
        - name: probe
          image: busybox
          resources: { requests: { memory: 16Mi } }
YAML
  run bash "$tmp/scripts/check-memory-limits.sh"
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
}

@test "memory-limit guard honors the allowlist exemption" {
  # 동일 위반이라도 allowlist에 등재되면 통과해야 한다.
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/scripts" "$tmp/platform/probe/prod" "$tmp/policy"
  cp "${BATS_TEST_DIRNAME}/../scripts/check-memory-limits.sh" "$tmp/scripts/"
  echo "Deployment/probe/probe   # 테스트 면제" > "$tmp/policy/memory-limit-allowlist.txt"
  cat > "$tmp/platform/probe/prod/deploy.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata: { name: probe, namespace: probe }
spec:
  template:
    spec:
      containers:
        - name: probe
          image: busybox
          resources: { requests: { memory: 16Mi } }
YAML
  run bash "$tmp/scripts/check-memory-limits.sh"
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
}
