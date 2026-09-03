#!/usr/bin/env bats
# 상주 워크로드 자원 가드: cpu·memory request + memory limit 필수 (vector OOM PR #85 포스트모템 +
# CPU 단일축 편향 해소). cpu limit은 비요구(throttling 회피 — SRE 권장). @test 이름은 영어(CJK 함정).
# CI-safe(소스 매니페스트 스캔, bun/TS 단일 — yq/python3 불요) → run-bats.sh gate 도메인에 자동 수집.
# ⚠️ red-green 레인의 `-ne 0`은 「가드가 위반을 거부했다」와 「가드가 판정 전에 죽었다」를 구별하지
#    못한다 — 도구를 지우면 bun의 rc도 비-0이다(실측: 대상 삭제 시 14레인 중 6개가 그대로 초록).
#    그래서 각 red-green 레인은 거부 문구(check-resource-limits.ts:127)를 함께 물고, setup은
#    피연산자 실재를 닫는다. cf. .scratch/operand-witness/issues/05
setup() { [ -f "${BATS_TEST_DIRNAME}/../tools/check-resource-limits.ts" ]; }

# 픽스처 트리를 git 추적 상태로 만든다. 가드의 열거는 공유 워커의 `platform-manifests` 스코프가
# 소유하고 그 스코프는 **tracked**(git ls-files) 열거를 쓴다 — untracked helm 캐시가 자동으로 빠지고
# CI와 로컬이 같은 집합을 본다. 따라서 픽스처도 추적 파일이어야 한다(단언 내용은 불변).
_track() {
  git -C "$1" init -q 2>/dev/null
  git -C "$1" add -A 2>/dev/null
}

# 정상 픽스처(scan-floor 통과용): cpu·memory request + memory limit 보유.
# ⚠️ 개수는 `tools/check-resource-limits.ts`의 MIN_SCAN(18)과 함께 움직인다 — 그보다 적으면
#    모든 픽스처 @test가 열거 붕괴로 죽는다(판정이 아니라 전제에서 죽어 red-green이 무의미해진다).
_seed_ok() {
  local root="$1" i
  for i in $(seq 1 18); do
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
  run bun "${BATS_TEST_DIRNAME}/../tools/check-resource-limits.ts" --repo-root "$tmp" --floor substrate=0
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- 'FAIL: cpu·memory request 또는 memory limit 없는'
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
  run bun "${BATS_TEST_DIRNAME}/../tools/check-resource-limits.ts" --repo-root "$tmp" --floor substrate=0
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- 'FAIL: cpu·memory request 또는 memory limit 없는'
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
  run bun "${BATS_TEST_DIRNAME}/../tools/check-resource-limits.ts" --repo-root "$tmp" --floor substrate=0
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- 'FAIL: cpu·memory request 또는 memory limit 없는'
}

# scan-floor는 **이 가드가** 소유한다 — 워커는 비어 있으면 조용히 빈 목록을 준다(열거자는 "글롭이
# 깨져 0건"과 "정당하게 0건"을 구별할 도메인 지식이 없다). 열거가 성공했는데 워크로드 kind 매치가
# 부족한 경우와, 열거 자체가 0건인 경우 **둘 다** 이 MIN_SCAN이 잡는다.
@test "resource guard enforces a minimum scan count (selector collapse = fail-loud)" {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/scripts" "$tmp/policy" "$tmp/platform/probe/prod"
  : > "$tmp/policy/memory-limit-allowlist.txt"
  # 열거는 성공하되(YAML 3건) 워크로드 kind는 0건 → MIN_SCAN 미달로 fail-loud.
  echo 'kind: ConfigMap'  > "$tmp/platform/probe/prod/a.yaml"
  echo 'kind: Service'    > "$tmp/platform/probe/prod/b.yaml"
  echo 'kind: Namespace'  > "$tmp/platform/probe/prod/c.yaml"
  _track "$tmp"
  run bun "${BATS_TEST_DIRNAME}/../tools/check-resource-limits.ts" --repo-root "$tmp" --floor substrate=0
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
  # 커널 이행 후 문구는 균일하다 — 라벨이 도메인을, hint가 원인 후보를 나른다.
  # 앵커를 둘 다 건다: 균일부가 바뀌면 규약 회귀이고, hint가 사라지면 진단 품질 회귀다.
  echo "$output" | grep -q '열거 붕괴'
  echo "$output" | grep -q 'grep 셀렉터 회귀'
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
  run bun "${BATS_TEST_DIRNAME}/../tools/check-resource-limits.ts" --repo-root "$tmp" --floor substrate=0 --exempt-max 1
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
  run bun "${BATS_TEST_DIRNAME}/../tools/check-resource-limits.ts" --repo-root "$tmp" --floor substrate=0
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
  run bun "${BATS_TEST_DIRNAME}/../tools/check-resource-limits.ts" --repo-root "$tmp" --floor substrate=0
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- 'FAIL: cpu·memory request 또는 memory limit 없는'
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
  run bun "${BATS_TEST_DIRNAME}/../tools/check-resource-limits.ts" --repo-root "$tmp" --floor substrate=0
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
  run bun "${BATS_TEST_DIRNAME}/../tools/check-resource-limits.ts" --repo-root "$tmp" --floor substrate=0 --exempt-max 1
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
  run bun "${BATS_TEST_DIRNAME}/../tools/check-resource-limits.ts" --repo-root "$tmp" --floor substrate=0
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- 'FAIL: cpu·memory request 또는 memory limit 없는'
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
  run bun "${BATS_TEST_DIRNAME}/../tools/check-resource-limits.ts" --repo-root "$tmp" --floor substrate=0
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- 'FAIL: cpu·memory request 또는 memory limit 없는'
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
  run bun "${BATS_TEST_DIRNAME}/../tools/check-resource-limits.ts" --repo-root "$tmp" --floor substrate=0
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
}

# ── 면제 목록의 증인(critic-C) ─────────────────────────────────────────────
# 한 줄 추가가 곧 상주 워크로드의 memory limit 면제인데, 이 목록에만 형제 둘
# (check-image-pins.sh:67-83 · check-alert-rules.ts ALLOWLIST)이 가진 "사유 강제"가 없었고
# "면제가 늘어났다"를 잴 상한도 없었다(cf. check-bats-accounting.sh의 EXCL_MAX 선례).
# 아래 셋이 그 규율의 증인이다 — 뮤테이션이 red를 내지 않으면 규율은 산문일 뿐이다.

@test "an allowlist entry without a reason is rejected" {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/scripts" "$tmp/platform/probe/prod" "$tmp/policy"
  printf 'Deployment/probe/probe\n' > "$tmp/policy/memory-limit-allowlist.txt"
  _seed_ok "$tmp"
  _track "$tmp"
  run bun "${BATS_TEST_DIRNAME}/../tools/check-resource-limits.ts" --repo-root "$tmp" --floor substrate=0 --exempt-max 1
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q '무근거 면제는 금지'
}

@test "a reason on the preceding line satisfies the requirement" {
  # check-image-pins.sh:68과 같은 규약 — 인라인 또는 **직전 줄** 주석.
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/scripts" "$tmp/platform/probe/prod" "$tmp/policy"
  printf '# 직전 줄 사유: 벤더 차트라 소스에 없다\nDeployment/probe/probe\n' > "$tmp/policy/memory-limit-allowlist.txt"
  _seed_ok "$tmp"
  _track "$tmp"
  run bun "${BATS_TEST_DIRNAME}/../tools/check-resource-limits.ts" --repo-root "$tmp" --floor substrate=0 --exempt-max 1
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
}

@test "the enforced-exemption count is capped (growth needs a reviewed constant bump)" {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/scripts" "$tmp/platform/probe/prod" "$tmp/policy"
  printf 'Deployment/probe/probe   # 사유 있음\n' > "$tmp/policy/memory-limit-allowlist.txt"
  _seed_ok "$tmp"
  _track "$tmp"
  # 기본 상한 0 = 실 트리의 현 강제 면제 건수. 1건이면 상한 초과로 fail-loud.
  run bun "${BATS_TEST_DIRNAME}/../tools/check-resource-limits.ts" --repo-root "$tmp" --floor substrate=0
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q '상한'
  echo "$output" | grep -q 'EXEMPT_MAX'
}

@test "a non-integer exempt-max is rejected instead of silently disabling the cap" {
  # Number("abc")는 NaN이고 `n > NaN`은 항상 false다 — 상한이 조용히 꺼지는 레포 등재 함정.
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/scripts" "$tmp/platform/probe/prod" "$tmp/policy"
  printf 'Deployment/probe/probe   # 사유 있음\n' > "$tmp/policy/memory-limit-allowlist.txt"
  _seed_ok "$tmp"
  _track "$tmp"
  run bun "${BATS_TEST_DIRNAME}/../tools/check-resource-limits.ts" --repo-root "$tmp" --floor substrate=0 --exempt-max abc
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q 'exempt-max'
}

# ── substrate 스코프(k3s-bootstrap) ↔ 메모리 원장 기계 대조 ────────────────────────────────
# `infra/k3s-bootstrap/storage`가 적용하는 상주 워크로드는 ArgoCD 밖이라(selfHeal 없음) 드리프트를
# 잡아 줄 것이 원장뿐인데, 그 원장 행은 **주석 한 줄로만** 지켜지는 수기 계상이었다. 실측(착지 전):
#   · provisioner 한 Deployment의 limit 64Mi→96Mi  → verify:ledger·check-resource-limits 둘 다 rc 0
#   · 원장의 local-path-storage 행 삭제             → 둘 다 rc 0
# 아래 레인들이 그 두 사고를 재현해 대조가 실제로 무는지 본다(양방향).
#
# ⚠️ 위 픽스처 레인들이 `--floor substrate=0`을 넘기는 이유: 그 트리엔 substrate 워크로드가 없고,
#    바닥값은 "0건이면 대조가 vacuous"를 막으려 1이다. 픽스처가 자기 크기를 명시하는 관례이고
#    (`--exempt-max` 선례), 프로덕션 호출은 floor-free다(ci-parity가 강제).

# substrate 워크로드 1개를 provisioner.yaml에 덧붙인다. $1=root $2=이름 $3=ns $4=req $5=limit $6=replicas
_sub_deploy() {
  mkdir -p "$1/infra/k3s-bootstrap/storage"
  cat >> "$1/infra/k3s-bootstrap/storage/provisioner.yaml" <<YAML
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: $2, namespace: $3 }
spec:
  replicas: $6
  template:
    spec:
      containers:
        - name: $2
          image: busybox
          resources: { requests: { cpu: 10m, memory: $4 }, limits: { memory: $5 } }
YAML
}

# 원장 행 1줄짜리 최소 원장. $1=root $2=행이름 $3=ns $4=req_mi $5=limit_mi
_sub_ledger() {
  mkdir -p "$1/docs"
  printf '| <!-- ledger:row --> %s | %s | %s | %s |\n' "$2" "$3" "$4" "$5" > "$1/docs/memory-ledger.md"
}

# 실 트리와 같은 모양(Deployment 2개 × req 32Mi/limit 64Mi = 행 64/128)의 정상 픽스처.
_seed_substrate_ok() {
  _seed_ok "$1"
  : > "$1/policy/memory-limit-allowlist.txt"
  _sub_deploy "$1" prov-a sub 32Mi 64Mi 1
  _sub_deploy "$1" prov-b sub 32Mi 64Mi 1
  _sub_ledger "$1" sub sub 64 128
}

@test "substrate workloads reconcile against the ledger row (positive control)" {
  tmp="$(mktemp -d)"; mkdir -p "$tmp/policy"
  _seed_substrate_ok "$tmp"
  _track "$tmp"
  run bun "${BATS_TEST_DIRNAME}/../tools/check-resource-limits.ts" --repo-root "$tmp"
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qE '^SCAN: check-resource-limits:substrate: 1$'
}

@test "raising a substrate manifest limit without the ledger row is rejected (red-green)" {
  tmp="$(mktemp -d)"; mkdir -p "$tmp/policy"
  _seed_ok "$tmp"
  : > "$tmp/policy/memory-limit-allowlist.txt"
  _sub_deploy "$tmp" prov-a sub 32Mi 64Mi 1
  _sub_deploy "$tmp" prov-b sub 32Mi 96Mi 1   # 96Mi — 원장은 여전히 128
  _sub_ledger "$tmp" sub sub 64 128
  _track "$tmp"
  run bun "${BATS_TEST_DIRNAME}/../tools/check-resource-limits.ts" --repo-root "$tmp"
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- 'FAIL: substrate 워크로드 선언과 docs/memory-ledger.md 행이 어긋난다'
  printf '%s' "$output" | grep -qF -- 'limit 160Mi'
}

@test "deleting the ledger row for a substrate namespace is rejected (the other direction)" {
  tmp="$(mktemp -d)"; mkdir -p "$tmp/policy"
  _seed_substrate_ok "$tmp"
  _sub_ledger "$tmp" other elsewhere 8 16   # 같은 원장, 다른 namespace 행만 남는다
  _track "$tmp"
  run bun "${BATS_TEST_DIRNAME}/../tools/check-resource-limits.ts" --repo-root "$tmp"
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- "namespace 'sub'의 원장 행이 0건"
}

# replicas는 곱해진다 — 원장 행은 namespace **총량**이고 파드 수만큼 노드가 문다.
# 이 조건은 위 두 레인이 밟지 않는다(둘 다 replicas 1) → 자기 증인을 따로 둔다.
@test "replicas multiply the substrate tally (the ledger row is a namespace total)" {
  tmp="$(mktemp -d)"; mkdir -p "$tmp/policy"
  _seed_ok "$tmp"
  : > "$tmp/policy/memory-limit-allowlist.txt"
  _sub_deploy "$tmp" prov-a sub 32Mi 64Mi 2   # 2 파드 = req 64Mi · limit 128Mi
  _sub_ledger "$tmp" sub sub 64 128
  _track "$tmp"
  run bun "${BATS_TEST_DIRNAME}/../tools/check-resource-limits.ts" --repo-root "$tmp"
  echo "$output"
  [ "$status" -eq 0 ]
  # 대조군 — replicas만 1로 내리면 같은 원장이 어긋난다(곱셈이 실제로 일어났다는 증거).
  rm -f "$tmp/infra/k3s-bootstrap/storage/provisioner.yaml"
  _sub_deploy "$tmp" prov-a sub 32Mi 64Mi 1
  _track "$tmp"
  run bun "${BATS_TEST_DIRNAME}/../tools/check-resource-limits.ts" --repo-root "$tmp"
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- 'limit 64Mi'
}

# namespace 미선언은 라이브에서 `default`로 떨어진다 — 어느 원장 행에도 귀속되지 않으므로
# 대조 자체가 성립하지 않는다. 조용히 합계에서 빠지면 그게 곧 예산 밖 워크로드다.
@test "a substrate workload without metadata.namespace is rejected, not silently unaccounted" {
  tmp="$(mktemp -d)"; mkdir -p "$tmp/policy" "$tmp/infra/k3s-bootstrap/storage"
  _seed_ok "$tmp"
  : > "$tmp/policy/memory-limit-allowlist.txt"
  cat > "$tmp/infra/k3s-bootstrap/storage/provisioner.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata: { name: prov-a }
spec:
  template:
    spec:
      containers:
        - name: prov-a
          image: busybox
          resources: { requests: { cpu: 10m, memory: 32Mi }, limits: { memory: 64Mi } }
YAML
  _sub_ledger "$tmp" sub sub 64 128
  _track "$tmp"
  run bun "${BATS_TEST_DIRNAME}/../tools/check-resource-limits.ts" --repo-root "$tmp"
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- 'metadata.namespace 미선언'
}

# 원장 부재를 "대조할 것이 없다"로 읽으면 그것이 곧 fail-open이다(readLedger가 막는 클래스와 동형).
@test "a missing ledger with substrate workloads present is a violation, not a skip" {
  tmp="$(mktemp -d)"; mkdir -p "$tmp/policy"
  _seed_substrate_ok "$tmp"
  rm -f "$tmp/docs/memory-ledger.md"
  _track "$tmp"
  run bun "${BATS_TEST_DIRNAME}/../tools/check-resource-limits.ts" --repo-root "$tmp"
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- '읽기 실패'
  printf '%s' "$output" | grep -qF -- 'fail-closed'
}

# substrate 스코프가 0건이면 대조의 **좌변이 사라진다** — 그 상태에서 "위반 0"은 통과가 아니라
# 무측정이고, 원장 행은 아무도 안 보는 채로 남는다(착지 전의 현실이 정확히 그것이었다).
@test "a substrate enumeration collapse dies on its own floor and withholds both markers" {
  tmp="$(mktemp -d)"; mkdir -p "$tmp/policy"
  _seed_ok "$tmp"
  : > "$tmp/policy/memory-limit-allowlist.txt"
  _sub_ledger "$tmp" sub sub 64 128
  _track "$tmp"   # substrate 매니페스트는 만들지 않는다 — platform 도메인만 성립한다
  run bun "${BATS_TEST_DIRNAME}/../tools/check-resource-limits.ts" --repo-root "$tmp"
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- 'FAIL: check-resource-limits:substrate:'
  printf '%s' "$output" | grep -q '열거 붕괴'
  printf '%s' "$output" | grep -q '무측정'
  # 붕괴 실행은 어느 도메인의 마커도 내지 않는다(일괄 방출 — platform은 통과했더라도).
  if printf '%s\n' "$output" | grep -q '^SCAN:'; then
    echo "붕괴 실행이 마커를 냈다: $output"; false
  fi
}

# 실 트리가 이 레인을 **실제로** 지난다는 증인 — 픽스처만 초록인 상태를 구별한다.
@test "the real tree emits the substrate scan marker with a non-zero count" {
  run bun "${BATS_TEST_DIRNAME}/../tools/check-resource-limits.ts" --repo-root "${BATS_TEST_DIRNAME}/.."
  echo "$output"
  [ "$status" -eq 0 ]
  n="$(printf '%s\n' "$output" | sed -n 's/^SCAN: check-resource-limits:substrate: //p')"
  [ -n "$n" ]
  [ "$n" -ge 1 ]
}
