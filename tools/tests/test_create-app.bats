#!/usr/bin/env bats
# create-app 생성기 — .app-config.yml → values.yaml + .bindings.json + apps.json + sealed 시크릿

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TMP="$(mktemp -d)"
  # 픽스처 homelab 루트(원장 + apps.json + 선프로비저닝된 리소스 핸들)
  FR="$TMP/repo"
  mkdir -p "$FR/apps" "$FR/docs" "$FR/infra/cloudflare" \
    "$FR/platform/cnpg/prod/databases" "$FR/platform/data-conn/prod"
  cat > "$FR/docs/memory-ledger.md" <<'EOF'
<!-- ledger:meta VM_ALLOCATABLE_MIB=11264 LIMIT_BUDGET_MIB=8704 -->
| component | namespace | req_mi | limit_mi |
|---|---|---:|---:|
| <!-- ledger:row --> base | kube-system | 100 | 200 |

**합계:** req ≈ 100 Mi · limit ≈ 200 Mi (반드시 ≤ 8704 Mi 유지).
EOF
  echo '[]' > "$FR/infra/cloudflare/apps.json"
  # 선프로비저닝된 db/cache 핸들 (Phase 5 산출물 모양)
  touch "$FR/platform/cnpg/prod/databases/orders.yaml"
  touch "$FR/platform/data-conn/prod/db-orders-conn.sealed.yaml"
  touch "$FR/platform/data-conn/prod/cache-sessions-conn.sealed.yaml"
  cat > "$TMP/.app-config.yml" <<'EOF'
kind: service
resources: { requests: {cpu: 50m, memory: 64Mi}, limits: {cpu: 200m, memory: 128Mi} }
route: { public: true, host: orders.example.com }
db: [orders]
redis: [sessions]
migrate: { cmd: [npm, run, migrate] }
deploy: { autoDeploy: false }
EOF
}
teardown() { rm -rf "$TMP"; }

gen() {
  run bun "$ROOT/tools/create-app.ts" --config "$TMP/.app-config.yml" --app orders \
    --repo ukyi-app/orders --domain example.com --repo-root "$FR" \
    --digest sha256:1111111111111111111111111111111111111111111111111111111111111111 \
    --tag sha-aaa1111000000000000000000000000000000000 "$@"
}

@test "create-app generates values.yaml with digest-pinned image" {
  gen
  [ "$status" -eq 0 ]
  grep -q "ghcr.io/ukyi-app/orders" "$FR/apps/orders/deploy/prod/values.yaml"
  grep -q "digest: sha256:1111" "$FR/apps/orders/deploy/prod/values.yaml"
}

@test "create-app wires db/redis SealedSecret conn handles into envFrom" {
  gen
  [ "$status" -eq 0 ]
  grep -q "db-orders-conn" "$FR/apps/orders/deploy/prod/values.yaml"
  grep -q "cache-sessions-conn" "$FR/apps/orders/deploy/prod/values.yaml"
}

@test "create-app writes the authoritative bindings registry (refcount + autoDeploy source)" {
  gen
  [ "$status" -eq 0 ]
  run jq -e '.db == ["orders"] and .redis == ["sessions"] and .autoDeploy == false' \
    "$FR/apps/orders/deploy/prod/.bindings.json"
  [ "$status" -eq 0 ]
}

@test "create-app registers public app in apps.json with active:false (no DNS before Healthy)" {
  gen
  [ "$status" -eq 0 ]
  run jq -e '.[0] == {name:"orders", host:"orders.example.com", public:true, active:false}' \
    "$FR/infra/cloudflare/apps.json"
  [ "$status" -eq 0 ]
}

@test "create-app rejects an unprovisioned db reference with a clear error" {
  sed -i '' 's/db: \[orders\]/db: [missing]/' "$TMP/.app-config.yml" 2>/dev/null \
    || sed -i 's/db: \[orders\]/db: [missing]/' "$TMP/.app-config.yml"
  gen
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "create-database"
}

@test "create-app rejects duplicate host in apps.json (silent toset collision guard)" {
  echo '[{"name":"other","host":"orders.example.com","public":true,"active":true}]' \
    > "$FR/infra/cloudflare/apps.json"
  gen
  [ "$status" -ne 0 ]
}

@test "create-app copies and validates a sealed secret, registering it in kustomization resources" {
  cat > "$TMP/sealed.yaml" <<'EOF'
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: orders-secrets
  namespace: prod
spec:
  encryptedData: { API_KEY: AgX... }
EOF
  cat >> "$TMP/.app-config.yml" <<'EOF'
secrets: [api-key]
EOF
  gen --sealed "$TMP/sealed.yaml"
  [ "$status" -eq 0 ]
  [ -f "$FR/apps/orders/deploy/prod/orders-secrets.sealed.yaml" ]
  grep -q "orders-secrets.sealed.yaml" "$FR/apps/orders/deploy/prod/kustomization.yaml"
  grep -q "orders-secrets" "$FR/apps/orders/deploy/prod/values.yaml" # envFrom secretRef
}

@test "create-app writes a checksum/secrets pod annotation so rotation rolls declaratively" {
  cat > "$TMP/sealed.yaml" <<'EOF'
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: orders-secrets
  namespace: prod
spec:
  encryptedData: { API_KEY: AgX... }
EOF
  cat >> "$TMP/.app-config.yml" <<'EOF'
secrets: [api-key]
EOF
  gen --sealed "$TMP/sealed.yaml"
  [ "$status" -eq 0 ]
  grep -q "checksum/secrets" "$FR/apps/orders/deploy/prod/values.yaml"
}

@test "create-app rejects a sealed secret with wrong namespace or name" {
  cat > "$TMP/sealed.yaml" <<'EOF'
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: orders-secrets
  namespace: default
spec:
  encryptedData: {}
EOF
  cat >> "$TMP/.app-config.yml" <<'EOF'
secrets: [api-key]
EOF
  gen --sealed "$TMP/sealed.yaml"
  [ "$status" -ne 0 ]
}

@test "create-app adds a ledger row and respects the budget gate" {
  gen
  [ "$status" -eq 0 ]
  grep -q "ledger:row --> orders" "$FR/docs/memory-ledger.md"
}

@test "create-app kustomization always exists (ArgoCD kustomize source contract)" {
  gen
  [ "$status" -eq 0 ]
  [ -f "$FR/apps/orders/deploy/prod/kustomization.yaml" ]
}

@test "create-app refuses a tombstoned resource reference (teardown race guard)" {
  echo '{"db:orders":{"state":"retained"}}' > "$FR/platform/data-conn/prod/.tombstones.json"
  gen
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "tombstone"
}
