#!/usr/bin/env bats
# provision-db CLI — 공유 pg 클러스터의 논리 DB 프로비저닝.
# Database CR + managed role(cluster.yaml) + SealedSecret 4개(owner/ro/conn/ro-conn)를 산출한다.
# kubeseal은 PATH 스텁(평문 비포함 SealedSecret 모양 출력)으로 대체 — 비밀번호/raw URL이
# stdout·파일 어디에도 노출되지 않음을 단언한다.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TMP="$(mktemp -d)"
  FIX="$TMP/repo"

  # 최소 픽스처 레포 — 실제 cluster.yaml 스타일(주석 + 인용 스칼라)을 라운드트립 보존 검증용으로 포함
  mkdir -p "$FIX/platform/cnpg/prod" "$FIX/tools"
  cat > "$FIX/platform/cnpg/prod/cluster.yaml" <<'EOF'
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: pg
  namespace: database
spec:
  instances: 1
  postgresql:
    parameters:
      shared_buffers: "256MB" # 인용 스칼라 보존 검증용
  storage:
    size: 40Gi
EOF
  cat > "$FIX/platform/cnpg/prod/kustomization.yaml" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: database
resources:
  - cluster.yaml # 기존 주석 보존 검증용
EOF
  : > "$FIX/tools/sealed-secrets-cert.pem"

  # kubeseal 스텁: stdin(JSON manifest)을 소비하고 SealedSecret 모양만 출력 — 평문 값은 절대 미출력
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/kubeseal" <<'EOF'
#!/bin/sh
exec bun -e '
let d = "";
process.stdin.on("data", (c) => (d += c)).on("end", () => {
  const m = JSON.parse(d);
  const keys = Object.keys(m.stringData || {});
  const out = [
    "apiVersion: bitnami.com/v1alpha1",
    "kind: SealedSecret",
    "metadata:",
    "  name: " + m.metadata.name,
    "  namespace: " + m.metadata.namespace,
    "spec:",
    "  encryptedData:",
    ...keys.map((k) => "    " + k + ": AgSTUBSEALED"),
    "  template:",
    "    metadata:",
    "      name: " + m.metadata.name,
    "      namespace: " + m.metadata.namespace,
    ...(m.type ? ["    type: " + m.type] : []),
  ];
  console.log(out.join("\n"));
});'
EOF
  chmod +x "$TMP/bin/kubeseal"
}

teardown() { rm -rf "$TMP"; }

provision() { PATH="$TMP/bin:$PATH" run bun "$ROOT/tools/provision-db.ts" "$@"; }

@test "provision-db emits a CNPG Database CR with owner==name, retain policy and extensions" {
  provision --name orders --extensions pgcrypto,citext --repo-root "$FIX"
  [ "$status" -eq 0 ]
  f="$FIX/platform/cnpg/prod/databases/orders.yaml"
  [ -f "$f" ]
  [ "$(yq '.apiVersion' "$f")" = "postgresql.cnpg.io/v1" ]
  [ "$(yq '.kind' "$f")" = "Database" ]
  [ "$(yq '.metadata.namespace' "$f")" = "database" ]
  [ "$(yq '.spec.cluster.name' "$f")" = "pg" ]
  [ "$(yq '.spec.name' "$f")" = "orders" ]
  [ "$(yq '.spec.owner' "$f")" = "orders" ]
  [ "$(yq '.spec.databaseReclaimPolicy' "$f")" = "retain" ]
  # extensions는 CNPG 계약 형태([{name, ensure}]) — ensure는 서버 주입 기본값이라 명시
  [ "$(yq '.spec.extensions[0].name' "$f")" = "pgcrypto" ]
  [ "$(yq '.spec.extensions[0].ensure' "$f")" = "present" ]
  [ "$(yq '.spec.extensions[1].name' "$f")" = "citext" ]
}

@test "provision-db registers the CR in databases kustomization and parent kustomization" {
  provision --name orders --repo-root "$FIX"
  [ "$status" -eq 0 ]
  dk="$FIX/platform/cnpg/prod/databases/kustomization.yaml"
  [ -f "$dk" ]
  grep -q "orders.yaml" "$dk"
  grep -q "db-orders-owner.sealed.yaml" "$dk"
  grep -q "db-orders-ro.sealed.yaml" "$dk"
  # databases/ 단독 kustomize build 가능 (KSOPS 없이 검증하는 경로)
  run kustomize build "$FIX/platform/cnpg/prod/databases"
  [ "$status" -eq 0 ]
  # 상위 kustomization에 databases/ 등록 + 기존 주석 보존(yaml 라운드트립)
  pk="$FIX/platform/cnpg/prod/kustomization.yaml"
  grep -q "databases" "$pk"
  grep -q "기존 주석 보존 검증용" "$pk"
}

@test "provision-db parent kustomization registration is idempotent across runs" {
  provision --name orders --repo-root "$FIX"
  [ "$status" -eq 0 ]
  provision --name billing --repo-root "$FIX"
  [ "$status" -eq 0 ]
  pk="$FIX/platform/cnpg/prod/kustomization.yaml"
  [ "$(grep -c "databases" "$pk")" -eq 1 ]
}

@test "provision-db adds owner and readonly managed roles to cluster.yaml with explicit SSA defaults" {
  provision --name orders --repo-root "$FIX"
  [ "$status" -eq 0 ]
  c="$FIX/platform/cnpg/prod/cluster.yaml"
  # owner 롤 — 서버 주입 기본값(ensure/inherit/connectionLimit) 명시 (SSA atomic 리스트 함정)
  [ "$(yq '.spec.managed.roles[] | select(.name=="orders") | .ensure' "$c")" = "present" ]
  [ "$(yq '.spec.managed.roles[] | select(.name=="orders") | .login' "$c")" = "true" ]
  [ "$(yq '.spec.managed.roles[] | select(.name=="orders") | .inherit' "$c")" = "true" ]
  [ "$(yq '.spec.managed.roles[] | select(.name=="orders") | .connectionLimit' "$c")" = "-1" ]
  [ "$(yq '.spec.managed.roles[] | select(.name=="orders") | .passwordSecret.name' "$c")" = "db-orders-owner" ]
  # 읽기전용 롤 (모드2 디버깅용)
  [ "$(yq '.spec.managed.roles[] | select(.name=="orders_ro") | .login' "$c")" = "true" ]
  [ "$(yq '.spec.managed.roles[] | select(.name=="orders_ro") | .passwordSecret.name' "$c")" = "db-orders-ro" ]
  # yaml 라운드트립 — 기존 주석/인용 스칼라 보존
  grep -q '"256MB"' "$c"
  grep -q "인용 스칼라 보존 검증용" "$c"
}

@test "provision-db never prints raw connection URLs or passwords" {
  provision --name orders --extensions pgcrypto --repo-root "$FIX"
  [ "$status" -eq 0 ]
  # 중간 negate는 침묵 통과 → run+status로 강제(check-bats-style.sh)
  run grep -qiE "postgres://|password=" <<<"$output"
  [ "$status" -ne 0 ]
  # 산출 파일 어디에도 평문 Secret 없음 (스텁이 stringData를 그대로 출력하지 않음을 포함 검증)
  run grep -rqE "postgres://|stringData" "$FIX/platform"
  [ "$status" -ne 0 ]
}

@test "provision-db rejects --owner because owner is always pinned to name" {
  provision --name orders --owner other --repo-root "$FIX"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "owner"
}

@test "provision-db rejects a duplicate database name" {
  provision --name orders --repo-root "$FIX"
  [ "$status" -eq 0 ]
  provision --name orders --repo-root "$FIX"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "이미"
}

@test "provision-db rejects a role name already present in cluster.yaml managed roles" {
  cat >> "$FIX/platform/cnpg/prod/cluster.yaml" <<'EOF'
  managed:
    roles:
      - name: legacy
        ensure: present
        login: true
        inherit: true
        connectionLimit: -1
        passwordSecret:
          name: db-legacy-owner
EOF
  provision --name legacy --repo-root "$FIX"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "롤"
}

@test "provision-db seals four SealedSecret files via kubeseal and registers conn handles in data-conn" {
  provision --name orders --repo-root "$FIX"
  [ "$status" -eq 0 ]
  own="$FIX/platform/cnpg/prod/databases/db-orders-owner.sealed.yaml"
  ro="$FIX/platform/cnpg/prod/databases/db-orders-ro.sealed.yaml"
  conn="$FIX/platform/data-conn/prod/db-orders-conn.sealed.yaml"
  roconn="$FIX/platform/data-conn/prod/db-orders-ro-conn.sealed.yaml"
  for f in "$own" "$ro" "$conn" "$roconn"; do
    [ -f "$f" ]
    grep -q "kind: SealedSecret" "$f"
  done
  # owner/ro는 database NS, conn 2종은 prod NS (SealedSecret strict-scope)
  grep -q "namespace: database" "$own"
  grep -q "namespace: database" "$ro"
  grep -q "namespace: prod" "$conn"
  grep -q "namespace: prod" "$roconn"
  # conn 핸들의 env 키 — 런타임(pooler)/마이그레이션(직결) 분리 + ro
  grep -q "ORDERS_DATABASE_URL" "$conn"
  grep -q "ORDERS_MIGRATE_DATABASE_URL" "$conn"
  grep -q "ORDERS_RO_DATABASE_URL" "$roconn"
  # data-conn kustomization 등록 (namespace: prod 강제) — grep으로 통일(lines 184-187과 동일).
  # yq 미사용: snap-confined yq가 /tmp 픽스처를 못 읽는 CI 함정 회피.
  ck="$FIX/platform/data-conn/prod/kustomization.yaml"
  [ -f "$ck" ]
  grep -q "namespace: prod" "$ck"
  grep -q "db-orders-conn.sealed.yaml" "$ck"
  grep -q "db-orders-ro-conn.sealed.yaml" "$ck"
}

@test "provision-db gives owner/ro password SealedSecrets a sync-wave ahead of the Cluster CR" {
  provision --name orders --repo-root "$FIX"
  [ "$status" -eq 0 ]
  own="$FIX/platform/cnpg/prod/databases/db-orders-owner.sealed.yaml"
  ro="$FIX/platform/cnpg/prod/databases/db-orders-ro.sealed.yaml"
  # CNPG가 managed role을 reconcile하기 전에 비번 Secret이 먼저 적용되도록, ArgoCD가 적용하는
  # SealedSecret '리소스 자체'의 top-level metadata에 wave -2(Cluster CR -1보다 앞섬)가 있어야 한다.
  # (kubeseal은 입력 Secret annotation을 spec.template로 옮기므로 seal 후 top-level 주입이 필요)
  grep -q 'argocd.argoproj.io/sync-wave: "-2"' "$own"
  grep -q 'argocd.argoproj.io/sync-wave: "-2"' "$ro"
  # conn 핸들(prod NS)은 CNPG 롤 게이팅과 무관 — wave를 받지 않는다(owner/ro만)
  conn="$FIX/platform/data-conn/prod/db-orders-conn.sealed.yaml"
  ! grep -q 'sync-wave' "$conn"
}

@test "provision-db merges into an existing data-conn kustomization without dropping entries" {
  mkdir -p "$FIX/platform/data-conn/prod"
  cat > "$FIX/platform/data-conn/prod/kustomization.yaml" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: prod
resources:
  - db-zeta-conn.sealed.yaml # 기존 항목 보존 검증용
EOF
  provision --name orders --repo-root "$FIX"
  [ "$status" -eq 0 ]
  ck="$FIX/platform/data-conn/prod/kustomization.yaml"
  grep -q "db-zeta-conn.sealed.yaml" "$ck"
  grep -q "db-orders-conn.sealed.yaml" "$ck"
  grep -q "기존 항목 보존 검증용" "$ck"
}

@test "provision-db converts kebab-case name to UPPER_SNAKE env keys" {
  provision --name my-shop --repo-root "$FIX"
  [ "$status" -eq 0 ]
  grep -q "MY_SHOP_DATABASE_URL" "$FIX/platform/data-conn/prod/db-my-shop-conn.sealed.yaml"
  grep -q "MY_SHOP_MIGRATE_DATABASE_URL" "$FIX/platform/data-conn/prod/db-my-shop-conn.sealed.yaml"
  grep -q "MY_SHOP_RO_DATABASE_URL" "$FIX/platform/data-conn/prod/db-my-shop-ro-conn.sealed.yaml"
}

@test "provision-db dry-run writes nothing and prints a plan JSON with checklist" {
  before_cluster="$(cat "$FIX/platform/cnpg/prod/cluster.yaml")"
  before_kust="$(cat "$FIX/platform/cnpg/prod/kustomization.yaml")"
  provision --name orders --extensions pgcrypto --repo-root "$FIX" --dry-run
  [ "$status" -eq 0 ]
  [ ! -e "$FIX/platform/cnpg/prod/databases" ]
  [ ! -e "$FIX/platform/data-conn" ]
  [ "$(cat "$FIX/platform/cnpg/prod/cluster.yaml")" = "$before_cluster" ]
  [ "$(cat "$FIX/platform/cnpg/prod/kustomization.yaml")" = "$before_kust" ]
  echo "$output" | jq -e '.dryRun == true' > /dev/null
  # ro GRANT SQL 후처리 필요성이 checklist로 표면화된다 (managed role은 GRANT를 관리하지 않음)
  echo "$output" | jq -re '.checklist[]' | grep -q "GRANT"
  ! echo "$output" | grep -qiE "postgres://|password="
}

@test "provision-db rejects reserved names that collide with bootstrap or system roles" {
  for reserved in app postgres streaming_replica; do
    provision --name "$reserved" --repo-root "$FIX"
    [ "$status" -ne 0 ]
  done
}

@test "provision-db rejects a -ro suffixed name (collides with readonly conn naming)" {
  provision --name orders-ro --repo-root "$FIX"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "ro"
}

@test "provision-db fails clearly when the sealed-secrets cert is missing" {
  rm "$FIX/tools/sealed-secrets-cert.pem"
  provision --name orders --repo-root "$FIX"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "sealed-secrets-cert"
}
