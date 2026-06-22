#!/usr/bin/env bats
# 상주 워크로드 자원 가드: cpu·memory request + memory limit 필수 (vector OOM PR #85 포스트모템 +
# CPU 단일축 편향 해소). cpu limit은 비요구(throttling 회피 — SRE 권장). @test 이름은 영어(CJK 함정).
# CI-safe(소스 매니페스트 yq/python 스캔, 라이브/age/docker 불요) → run-bats.sh gate 도메인에 자동 수집.

# 정상 픽스처(scan-floor 통과용 10건): cpu·memory request + memory limit 보유.
_seed_ok() {
  local root="$1" i
  for i in $(seq 1 10); do
    mkdir -p "$root/platform/ok$i/prod"
    cat > "$root/platform/ok$i/prod/deploy.yaml" <<YAML
apiVersion: apps/v1
kind: Deployment
metadata: { name: ok$i, namespace: ok$i }
spec:
  template:
    spec:
      containers:
        - name: ok$i
          image: busybox
          resources: { requests: { cpu: 25m, memory: 16Mi }, limits: { memory: 16Mi } }
YAML
  done
}

@test "all resident workload containers declare cpu+memory requests and a memory limit (or allowlisted)" {
  run bash "${BATS_TEST_DIRNAME}/../scripts/check-resource-limits.sh"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "resource guard fails on a workload missing requests and memory limit (red-green)" {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/scripts" "$tmp/platform/probe/prod" "$tmp/policy"
  cp "${BATS_TEST_DIRNAME}/../scripts/check-resource-limits.sh" "$tmp/scripts/"
  : > "$tmp/policy/memory-limit-allowlist.txt"
  _seed_ok "$tmp"
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
  run bash "$tmp/scripts/check-resource-limits.sh"
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
}

@test "resource guard fails on a workload missing only a CPU request" {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/scripts" "$tmp/platform/probe/prod" "$tmp/policy"
  cp "${BATS_TEST_DIRNAME}/../scripts/check-resource-limits.sh" "$tmp/scripts/"
  : > "$tmp/policy/memory-limit-allowlist.txt"
  _seed_ok "$tmp"
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
          resources: { requests: { memory: 16Mi }, limits: { memory: 64Mi } }
YAML
  run bash "$tmp/scripts/check-resource-limits.sh"
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
}

@test "resource guard fails on a workload missing only a memory limit (OOM bound)" {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/scripts" "$tmp/platform/probe/prod" "$tmp/policy"
  cp "${BATS_TEST_DIRNAME}/../scripts/check-resource-limits.sh" "$tmp/scripts/"
  : > "$tmp/policy/memory-limit-allowlist.txt"
  _seed_ok "$tmp"
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
          resources: { requests: { cpu: 25m, memory: 16Mi } }
YAML
  run bash "$tmp/scripts/check-resource-limits.sh"
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
}

@test "resource guard enforces a minimum scan count (selector collapse = fail-loud)" {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/scripts" "$tmp/policy" "$tmp/platform"   # platform 비어있음 = 0 매치
  cp "${BATS_TEST_DIRNAME}/../scripts/check-resource-limits.sh" "$tmp/scripts/"
  : > "$tmp/policy/memory-limit-allowlist.txt"
  run bash "$tmp/scripts/check-resource-limits.sh"
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
}

@test "resource guard honors the allowlist exemption" {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/scripts" "$tmp/platform/probe/prod" "$tmp/policy"
  cp "${BATS_TEST_DIRNAME}/../scripts/check-resource-limits.sh" "$tmp/scripts/"
  echo "Deployment/probe/probe   # 테스트 면제" > "$tmp/policy/memory-limit-allowlist.txt"
  _seed_ok "$tmp"
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
  run bash "$tmp/scripts/check-resource-limits.sh"
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
}
