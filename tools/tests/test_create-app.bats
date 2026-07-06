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
  echo '{"platform_hosts":["argocd-webhook.ukyi.app","files.ukyi.app"]}' > "$FR/infra/cloudflare/reserved-hosts.json"
  cat > "$TMP/.app-config.yml" <<'EOF'
kind: web
resources: { requests: {cpu: 50m, memory: 64Mi}, limits: {cpu: 200m, memory: 128Mi} }
route: { public: true, host: orders.example.com }
deploy: { autoDeploy: false }
EOF
  mkdir -p "$FR/platform/victoria-stack/prod"
  printf 'apiVersion: batch/v1\nkind: CronJob\nmetadata: { name: digest-exporter }\nspec:\n  jobTemplate:\n    spec:\n      template:\n        spec:\n          containers:\n            - name: digest-exporter\n              env:\n                - name: APPS\n                  value: ""\n' > "$FR/platform/victoria-stack/prod/digest-exporter.yaml"
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

@test "create-app values.yaml has no migrate/db.enabled (migrate removed)" {
  gen
  [ "$status" -eq 0 ]
  run grep -E "migrateCmd|^db:" "$FR/apps/orders/deploy/prod/values.yaml"
  [ "$status" -ne 0 ]   # migrate Job 제거 → values.db.enabled/migrateCmd 미생성
}

@test "bindings.json records only autoDeploy (no db/redis — connection is a sealed secret)" {
  gen
  [ "$status" -eq 0 ]
  run jq -e '(has("db")|not) and (has("redis")|not) and .autoDeploy == false' \
    "$FR/apps/orders/deploy/prod/.bindings.json"
  [ "$status" -eq 0 ]
}

@test "create-app registers public app in apps.json with active:true (merge exposes DNS)" {
  gen
  [ "$status" -eq 0 ]
  run jq -e '.[0] == {name:"orders", host:"orders.example.com", public:true, active:true}' \
    "$FR/infra/cloudflare/apps.json"
  [ "$status" -eq 0 ]
}

@test "create-app records an .activation marker for a public app (audit re-exposure gate coverage)" {
  # 공개 생성은 재노출 감사(audit-orphans activation-exposure-drift)가 검사할 .activation 마커를
  # activate-app --flip과 동일 포맷으로 남겨야 한다(마커 없으면 게이트에서 영구 제외).
  gen
  [ "$status" -eq 0 ]
  M="$FR/apps/orders/deploy/prod/.activation"
  [ -f "$M" ]
  run jq -e '.registry == {name:"orders", host:"orders.example.com", public:true}' "$M"
  [ "$status" -eq 0 ]
  # sha/syncedRev는 생성 시점 미확정(PR 머지 sha는 미래)이라 null이어야 한다.
  run jq -e '.sha == null and .syncedRev == null' "$M"
  [ "$status" -eq 0 ]
}

@test "create-app marker surfaceHash matches the committed canonical hash (no activation-surface-drift on merge)" {
  # working-tree에서 산출한 surfaceHash가 커밋 후 surfaceHash(HEAD)와 동일해야 머지 직후 audit이
  # activation-surface-drift(오탐)를 내지 않는다. git 레포로 커밋 후 공용 lib와 대조한다.
  git -C "$FR" init -q -b main; git -C "$FR" config user.email t@t; git -C "$FR" config user.name t
  gen
  [ "$status" -eq 0 ]
  M="$FR/apps/orders/deploy/prod/.activation"
  git -C "$FR" add -A; git -C "$FR" commit -qm "create orders"
  expected=$(bun "$ROOT/tools/lib/surface-hash.ts" "$FR" HEAD orders)
  [ -n "$expected" ]
  run jq -r '.surfaceHash' "$M"
  [ "$output" == "$expected" ]
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
  gen --sealed "$TMP/sealed.yaml"
  [ "$status" -ne 0 ]
}

@test "create-app rejects invalid sealed encryptedData key names" {
  cat > "$TMP/sealed.yaml" <<'EOF'
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: orders-secrets
  namespace: prod
spec:
  encryptedData: { bad-key: AgX... }
EOF
  gen --sealed "$TMP/sealed.yaml"
  [ "$status" -ne 0 ]
}

@test "create-app allows DATABASE_ADMIN_URL when it is already sealed" {
  cat > "$TMP/sealed.yaml" <<'EOF'
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: orders-secrets
  namespace: prod
spec:
  encryptedData: { DATABASE_ADMIN_URL: AgX... }
EOF
  gen --sealed "$TMP/sealed.yaml"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "DATABASE_ADMIN_URL"
}

@test "create-app disables metrics by default for web apps" {
  gen
  [ "$status" -eq 0 ]
  yq -e '.metrics.enabled == false' "$FR/apps/orders/deploy/prod/values.yaml"
}

@test "create-app preserves metrics opt-in from app config" {
  cat >> "$TMP/.app-config.yml" <<'EOF'
metrics: { enabled: true }
EOF
  gen
  [ "$status" -eq 0 ]
  yq -e '.metrics.enabled == true' "$FR/apps/orders/deploy/prod/values.yaml"
}

@test "create-app maps kind=site to internal sws without exposing static.server in app config" {
  cat > "$TMP/.app-config.yml" <<'EOF'
kind: site
resources: { requests: {cpu: 10m, memory: 32Mi}, limits: {cpu: 100m, memory: 64Mi} }
route: { public: false }
EOF
  gen
  [ "$status" -eq 0 ]
  yq -e '.kind == "site" and .static.server == "sws" and .route.host == "orders.home.example.com"' \
    "$FR/apps/orders/deploy/prod/values.yaml"
}

@test "create-app rejects static.server in external app config" {
  cat > "$TMP/.app-config.yml" <<'EOF'
kind: site
resources: { requests: {cpu: 10m, memory: 32Mi}, limits: {cpu: 100m, memory: 64Mi} }
route: { public: false }
static: { server: sws }
EOF
  gen
  [ "$status" -ne 0 ]
}

@test "create-app rejects legacy kind=service with actionable message (rename gate)" {
  cat > "$TMP/.app-config.yml" <<'EOF'
kind: service
resources: { requests: {cpu: 50m, memory: 64Mi}, limits: {cpu: 200m, memory: 128Mi} }
route: { public: false }
EOF
  gen
  [ "$status" -ne 0 ]
  echo "$output" | grep -Fq "web"   # 안내가 신값 web을 가리켜야
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

@test "create-app wires the app into digest-exporter APPS (R6 drift tracking)" {
  gen
  [ "$status" -eq 0 ]
  grep -q 'orders=ghcr.io/ukyi-app/orders:sha-aaa1111' "$FR/platform/victoria-stack/prod/digest-exporter.yaml"
}

@test "create-app rejects a reserved platform host (reserved-hosts.json SSOT)" {
  cat > "$TMP/.app-config.yml" <<'EOF'
kind: web
resources: { requests: {cpu: 50m, memory: 64Mi}, limits: {cpu: 200m, memory: 128Mi} }
route: { public: true, host: files.ukyi.app }
EOF
  run bun "$ROOT/tools/create-app.ts" --config "$TMP/.app-config.yml" --app orders \
    --repo ukyi-app/orders --domain ukyi.app --repo-root "$FR" \
    --digest sha256:1111111111111111111111111111111111111111111111111111111111111111 \
    --tag sha-aaa1111000000000000000000000000000000000
  [ "$status" -ne 0 ]
  echo "$output" | grep -Fq "예약 host"
}

@test "create-app rejects an internal app whose host collides with an existing app's route.host (mis-routing guard)" {
  mkdir -p "$FR/apps/other/deploy/prod"
  printf 'route: { host: shared.home.example.com, public: false }\n' > "$FR/apps/other/deploy/prod/values.yaml"
  cat > "$TMP/.app-config.yml" <<'EOF'
kind: web
resources: { requests: {cpu: 50m, memory: 64Mi}, limits: {cpu: 200m, memory: 128Mi} }
route: { public: false, host: shared.home.example.com }
EOF
  run bun "$ROOT/tools/create-app.ts" --config "$TMP/.app-config.yml" --app orders \
    --repo ukyi-app/orders --domain example.com --repo-root "$FR" \
    --digest sha256:1111111111111111111111111111111111111111111111111111111111111111 \
    --tag sha-aaa1111000000000000000000000000000000000
  [ "$status" -ne 0 ]
  echo "$output" | grep -Fq "이미 배선"
}
