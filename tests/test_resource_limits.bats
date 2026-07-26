#!/usr/bin/env bats
# 상주 워크로드 자원 가드: cpu·memory request + memory limit 필수 (vector OOM PR #85 포스트모템 +
# CPU 단일축 편향 해소). cpu limit은 비요구(throttling 회피 — SRE 권장). @test 이름은 영어(CJK 함정).
# CI-safe(소스 매니페스트 스캔, bun/TS 단일 — yq/python3 불요) → run-bats.sh gate 도메인에 자동 수집.

# 픽스처 트리를 git 추적 상태로 만든다. 가드의 열거는 공유 워커의 `platform-manifests` 스코프가
# 소유하고 그 스코프는 **tracked**(git ls-files) 열거를 쓴다 — untracked helm 캐시가 자동으로 빠지고
# CI와 로컬이 같은 집합을 본다. 따라서 픽스처도 추적 파일이어야 한다(단언 내용은 불변).
_track() {
  git -C "$1" init -q 2>/dev/null
  git -C "$1" add -A 2>/dev/null
}

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
  run bun "${BATS_TEST_DIRNAME}/../tools/check-resource-limits.ts" --repo-root "${BATS_TEST_DIRNAME}/.."
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "resource guard fails on a workload missing requests and memory limit (red-green)" {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/scripts" "$tmp/platform/probe/prod" "$tmp/policy"
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
  _track "$tmp"
  run bun "${BATS_TEST_DIRNAME}/../tools/check-resource-limits.ts" --repo-root "$tmp"
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
}

@test "resource guard fails on a workload missing only a CPU request" {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/scripts" "$tmp/platform/probe/prod" "$tmp/policy"
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
  _track "$tmp"
  run bun "${BATS_TEST_DIRNAME}/../tools/check-resource-limits.ts" --repo-root "$tmp"
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
}

@test "resource guard fails on a workload missing only a memory limit (OOM bound)" {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/scripts" "$tmp/platform/probe/prod" "$tmp/policy"
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
  _track "$tmp"
  run bun "${BATS_TEST_DIRNAME}/../tools/check-resource-limits.ts" --repo-root "$tmp"
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
}

# 두 바닥값은 성격이 다르고 **각각 따로** 증명해야 한다:
#   ① 워커의 열거 붕괴 바닥값 — 스코프가 아무것도 못 잡음(platform에 YAML 0건)
#   ② 이 가드의 MIN_SCAN — 열거는 성공했는데 **워크로드 kind 매치**가 부족함
# ②를 ①로 덮으면(빈 platform) 커널이 먼저 throw해서 MIN_SCAN 경로가 영영 실행되지 않는다.
@test "resource guard enforces a minimum scan count (selector collapse = fail-loud)" {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/scripts" "$tmp/policy" "$tmp/platform/probe/prod"
  : > "$tmp/policy/memory-limit-allowlist.txt"
  # 열거는 성공하되(YAML 3건) 워크로드 kind는 0건 → MIN_SCAN=10 미달로 fail-loud.
  echo 'kind: ConfigMap'  > "$tmp/platform/probe/prod/a.yaml"
  echo 'kind: Service'    > "$tmp/platform/probe/prod/b.yaml"
  echo 'kind: Namespace'  > "$tmp/platform/probe/prod/c.yaml"
  _track "$tmp"
  run bun "${BATS_TEST_DIRNAME}/../tools/check-resource-limits.ts" --repo-root "$tmp"
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '스캔 대상'
}

# 워커의 열거 붕괴는 콜사이트가 소유한다 — raw 스택 트레이스가 아니라 이 가드의 `FAIL:` 규약으로.
@test "enumeration collapse surfaces as the guard's FAIL line and not a stack trace" {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/scripts" "$tmp/policy" "$tmp/platform"   # platform에 YAML 0건 = 열거 붕괴
  : > "$tmp/policy/memory-limit-allowlist.txt"
  _track "$tmp"
  run bun "${BATS_TEST_DIRNAME}/../tools/check-resource-limits.ts" --repo-root "$tmp"
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q '^FAIL: repo-walk'
}

@test "resource guard honors the allowlist exemption" {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/scripts" "$tmp/platform/probe/prod" "$tmp/policy"
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
  _track "$tmp"
  run bun "${BATS_TEST_DIRNAME}/../tools/check-resource-limits.ts" --repo-root "$tmp"
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
}

@test "GOMEMLIMIT must not exceed 0.95x the memory limit (right-size coupling)" {
  # 실 매니페스트: vmalert 정정(57MiB) 후 통과. 이 @test가 red면 GOMEMLIMIT 드리프트가 남아있는 것.
  run bun "${BATS_TEST_DIRNAME}/../tools/check-resource-limits.ts" --repo-root "${BATS_TEST_DIRNAME}/.."
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "resource guard flags a container whose GOMEMLIMIT exceeds 0.95x limit (red-green)" {
  tmp="$(mktemp -d)"; mkdir -p "$tmp/scripts" "$tmp/platform/probe/prod" "$tmp/policy"
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
          env: [{ name: GOMEMLIMIT, value: "115MiB" }]
          resources: { requests: { cpu: 25m, memory: 16Mi }, limits: { memory: 64Mi } }
YAML
  _track "$tmp"
  run bun "${BATS_TEST_DIRNAME}/../tools/check-resource-limits.ts" --repo-root "$tmp"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'GOMEMLIMIT'
  rm -rf "$tmp"
}

# ── CNPG CR 커버리지: Cluster(spec.resources)·Pooler(spec.template.spec.containers[]) ──
# 이들은 kind가 Deployment/DaemonSet/StatefulSet가 아니라 예전엔 스캔 밖이었다 → 자원 블록이
# 실수로 제거돼도 GREEN이던 블라인드스팟. 아래 red-green으로 스캔 편입을 고정한다.

@test "resource guard fails on a CNPG Cluster missing spec.resources (red-green)" {
  tmp="$(mktemp -d)"; mkdir -p "$tmp/platform/cnpg/prod" "$tmp/policy"
  : > "$tmp/policy/memory-limit-allowlist.txt"
  _seed_ok "$tmp"
  cat > "$tmp/platform/cnpg/prod/cluster.yaml" <<'YAML'
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: { name: pg, namespace: database }
spec:
  instances: 1
YAML
  _track "$tmp"
  run bun "${BATS_TEST_DIRNAME}/../tools/check-resource-limits.ts" --repo-root "$tmp"
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
}

@test "resource guard passes a CNPG Cluster that declares spec.resources" {
  tmp="$(mktemp -d)"; mkdir -p "$tmp/platform/cnpg/prod" "$tmp/policy"
  : > "$tmp/policy/memory-limit-allowlist.txt"
  _seed_ok "$tmp"
  cat > "$tmp/platform/cnpg/prod/cluster.yaml" <<'YAML'
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: { name: pg, namespace: database }
spec:
  instances: 1
  resources:
    requests: { cpu: 250m, memory: 768Mi }
    limits: { cpu: "1", memory: 1Gi }
YAML
  _track "$tmp"
  run bun "${BATS_TEST_DIRNAME}/../tools/check-resource-limits.ts" --repo-root "$tmp"
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
}

@test "resource guard honors an allowlist exemption for a CNPG Cluster" {
  tmp="$(mktemp -d)"; mkdir -p "$tmp/platform/cnpg/prod" "$tmp/policy"
  echo "Cluster/pg/postgres   # 테스트 면제" > "$tmp/policy/memory-limit-allowlist.txt"
  _seed_ok "$tmp"
  cat > "$tmp/platform/cnpg/prod/cluster.yaml" <<'YAML'
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: { name: pg, namespace: database }
spec:
  instances: 1
YAML
  _track "$tmp"
  run bun "${BATS_TEST_DIRNAME}/../tools/check-resource-limits.ts" --repo-root "$tmp"
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
}

@test "resource guard fails on a CNPG Pooler whose pgbouncer container drops resources (red-green)" {
  tmp="$(mktemp -d)"; mkdir -p "$tmp/platform/cnpg/prod" "$tmp/policy"
  : > "$tmp/policy/memory-limit-allowlist.txt"
  _seed_ok "$tmp"
  cat > "$tmp/platform/cnpg/prod/pooler.yaml" <<'YAML'
apiVersion: postgresql.cnpg.io/v1
kind: Pooler
metadata: { name: pg-pooler-rw, namespace: database }
spec:
  cluster: { name: pg }
  instances: 1
  type: rw
  template:
    spec:
      containers:
        - name: pgbouncer
YAML
  _track "$tmp"
  run bun "${BATS_TEST_DIRNAME}/../tools/check-resource-limits.ts" --repo-root "$tmp"
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
}

@test "resource guard fails on a CNPG Pooler with no template (unlimited pgbouncer)" {
  tmp="$(mktemp -d)"; mkdir -p "$tmp/platform/cnpg/prod" "$tmp/policy"
  : > "$tmp/policy/memory-limit-allowlist.txt"
  _seed_ok "$tmp"
  cat > "$tmp/platform/cnpg/prod/pooler.yaml" <<'YAML'
apiVersion: postgresql.cnpg.io/v1
kind: Pooler
metadata: { name: pg-pooler-rw, namespace: database }
spec:
  cluster: { name: pg }
  instances: 1
  type: rw
YAML
  _track "$tmp"
  run bun "${BATS_TEST_DIRNAME}/../tools/check-resource-limits.ts" --repo-root "$tmp"
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
}

@test "resource guard passes a CNPG Pooler that declares container resources" {
  tmp="$(mktemp -d)"; mkdir -p "$tmp/platform/cnpg/prod" "$tmp/policy"
  : > "$tmp/policy/memory-limit-allowlist.txt"
  _seed_ok "$tmp"
  cat > "$tmp/platform/cnpg/prod/pooler.yaml" <<'YAML'
apiVersion: postgresql.cnpg.io/v1
kind: Pooler
metadata: { name: pg-pooler-rw, namespace: database }
spec:
  cluster: { name: pg }
  instances: 1
  type: rw
  template:
    spec:
      containers:
        - name: pgbouncer
          resources:
            requests: { cpu: 25m, memory: 32Mi }
            limits: { cpu: 200m, memory: 128Mi }
YAML
  _track "$tmp"
  run bun "${BATS_TEST_DIRNAME}/../tools/check-resource-limits.ts" --repo-root "$tmp"
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
}
